#!/usr/bin/env python3
"""Render system, HAProxy, and Authentik configuration files from .env and *.tpl templates."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
ENV_PATH = ROOT_DIR / ".env"
CHECK_SCRIPT = ROOT_DIR / "scripts" / "check_env_sync.py"

KEY_VALUE_RE = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$")
PLACEHOLDER_RE = re.compile(r"(?<!\$)\$\{([A-Z][A-Z0-9_]*)\}")
DOMAIN_VALID_RE = re.compile(r"^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = KEY_VALUE_RE.match(raw_line)
        if match:
            key, val = match.group(1), match.group(2)
            if len(val) >= 2 and val[0] == val[-1] and val[0] in {"'", '"'}:
                val = val[1:-1]
            env[key] = val
    return env


def slugify_domain(domain: str) -> str:
    return re.sub(r"[^a-zA-Z0-9]+", "_", domain.strip().lower()).strip("_")


def build_dynamic_blocks(env: dict[str, str]) -> dict[str, str]:
    """Generate role-specific HAProxy blocks for local-all-in-one, prod-hub, and prod-satellite."""
    mode = env.get("DEPLOY_MODE", "local-all-in-one")
    portal_domain = env["OPENMANAGER_PUBLIC_DOMAIN"]
    auth_domain = env["AUTHENTIK_DOMAIN"]
    auth_proxy_port = env["AUTHENTIK_PROXY_LOOPBACK_PORT"]
    agent_api_port = env["OPENMANAGER_AGENT_API_LOOPBACK_PORT"]
    local_idp_port = env["LOCAL_IDP_LOOPBACK_PORT"]
    app_domain = env["APP_PUBLIC_DOMAIN"]
    app_port = env["APP_LOOPBACK_PORT"]

    inbound_use_lines: list[str] = []
    inbound_backends: list[str] = []

    # 1. Hub / Local 1-Server Control Plane routes (OpenManager + Authentik Main)
    if mode in {"local-all-in-one", "prod-hub"}:
        inbound_use_lines.extend(
            [
                "    # [HUB] Satellite haproxy-agent pull endpoints (strictly path + X-API-Key gated)",
                f"    acl is_portal_host hdr(host) -i {portal_domain}",
                "    acl is_agent_pull_path path_beg /api/agents /api/clusters /api/configuration/agents/",
                "    acl has_agent_api_key req.hdr(X-API-Key) -m found",
                "    use_backend be_openmanager_agent_api if is_portal_host is_agent_pull_path has_agent_api_key",
                "",
                "    # [HUB] Human browser access to OpenManager -> gated 100% by Authentik Proxy SSO",
                "    use_backend be_openmanager_sso_proxy if is_portal_host",
                "",
                "    # [HUB] Authentik Main Identity Provider",
                f"    use_backend be_authentik_idp if {{ hdr(host) -i {auth_domain} }}",
            ]
        )
        inbound_backends.extend(
            [
                "backend be_openmanager_sso_proxy\n"
                "    mode http\n"
                "    timeout tunnel 3600s\n"
                f"    server authentik_proxy 127.0.0.1:{auth_proxy_port} check",
                "backend be_openmanager_agent_api\n"
                "    mode http\n"
                f"    server openmanager_router 127.0.0.1:{agent_api_port} check",
                "backend be_authentik_idp\n"
                "    mode http\n"
                "    timeout tunnel 3600s\n"
                f"    server authentik_server 127.0.0.1:{local_idp_port} check",
            ]
        )

    # 2. Satellite / Local 1-Server Business Application routes
    if mode in {"local-all-in-one", "prod-satellite"}:
        inbound_use_lines.extend(
            [
                "",
                "    # [SATELLITE] Business / Mock Application traffic",
                f"    use_backend be_business_app if {{ hdr(host) -i {app_domain} }}",
            ]
        )
        inbound_backends.append(
            "backend be_business_app\n"
            "    mode http\n"
            f"    server service_a 127.0.0.1:{app_port} check"
        )

    # 3. Outbound SNI Passthrough rules
    outbound_use_lines: list[str] = []
    outbound_backends: list[str] = []

    if mode in {"local-all-in-one", "prod-hub"}:
        wss_timeout = env["OUTBOUND_WSS_TIMEOUT"]
        idp_ip = env["AUTHENTIK_MAIN_BACKEND_IP"]
        outbound_use_lines.append(
            f"    use_backend be_out_authentik_main if {{ req.ssl_sni -i {auth_domain} }}"
        )
        outbound_backends.append(
            "backend be_out_authentik_main\n"
            "    mode tcp\n"
            f"    timeout server {wss_timeout}\n"
            f"    timeout tunnel {wss_timeout}\n"
            "    option srvtcpka\n"
            f"    server authentik_main {idp_ip}:443"
        )

    # External partner allowlisted domains (OUTBOUND_ALLOWED_DOMAINS)
    raw_domains = env.get("OUTBOUND_ALLOWED_DOMAINS", "")
    domains: list[str] = []
    for item in raw_domains.split(","):
        candidate = item.strip().lower()
        if not candidate:
            continue
        if not DOMAIN_VALID_RE.match(candidate):
            raise ValueError(f"Invalid domain in OUTBOUND_ALLOWED_DOMAINS: `{candidate}`")
        if candidate not in domains:
            domains.append(candidate)

    for domain in domains:
        slug = slugify_domain(domain)
        backend_name = f"be_out_{slug}"
        outbound_use_lines.append(
            f"    use_backend {backend_name} if {{ req.ssl_sni -i {domain} }}"
        )
        outbound_backends.append(
            f"backend {backend_name}\n"
            "    mode tcp\n"
            "    default-server init-addr last,libc,none resolvers host_dns resolve-prefer ipv4\n"
            f"    server srv_{slug} {domain}:443"
        )

    return {
        "__HAPROXY_INBOUND_ROLE_USE_BACKENDS__": "\n".join(inbound_use_lines),
        "__HAPROXY_INBOUND_ROLE_BACKENDS__": "\n\n".join(inbound_backends),
        "__HAPROXY_OUTBOUND_USE_BACKENDS__": "\n".join(outbound_use_lines)
        if outbound_use_lines
        else "    # No outbound SNI allowlist entries configured",
        "__HAPROXY_OUTBOUND_BACKENDS__": "\n\n".join(outbound_backends)
        if outbound_backends
        else "# No outbound SNI backends configured",
    }


def render_template(tpl_path: Path, out_path: Path, env: dict[str, str], blocks: dict[str, str]) -> None:
    content = tpl_path.read_text(encoding="utf-8")
    for marker, block_text in blocks.items():
        content = content.replace(marker, block_text)

    missing_keys: list[str] = []

    def replacer(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in env:
            if key not in missing_keys:
                missing_keys.append(key)
            return match.group(0)
        return env[key]

    rendered = PLACEHOLDER_RE.sub(replacer, content)
    if missing_keys:
        raise KeyError(
            f"Template {tpl_path.relative_to(ROOT_DIR)} references missing .env keys: "
            f"{', '.join(missing_keys)}"
        )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(rendered.replace("\r\n", "\n").encode("utf-8"))
    out_display = (
        out_path.relative_to(ROOT_DIR).as_posix()
        if out_path.is_relative_to(ROOT_DIR)
        else out_path.as_posix()
    )
    print(f"[RENDER] {tpl_path.relative_to(ROOT_DIR).as_posix()} -> {out_display}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Render configuration templates using .env.")
    parser.add_argument(
        "--skip-env-check",
        action="store_true",
        help="Skip invoking check_env_sync.py before rendering (used only in isolated unit tests).",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=ENV_PATH,
        help="Path to environment file (defaults to repository .env).",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=ROOT_DIR,
        help="Root directory where rendered files are written (defaults to repository root).",
    )
    args = parser.parse_args()

    if not args.skip_env_check and args.env_file.resolve() == ENV_PATH.resolve():
        proc = subprocess.run([sys.executable, str(CHECK_SCRIPT)], cwd=str(ROOT_DIR))
        if proc.returncode != 0:
            print("[FAIL] Aborting render because check_env_sync.py failed.", file=sys.stderr)
            return proc.returncode

    if not args.env_file.exists():
        print(f"[FAIL] Environment file not found: {args.env_file}", file=sys.stderr)
        return 1

    env = load_env(args.env_file)
    blocks = build_dynamic_blocks(env)

    template_pairs = [
        (ROOT_DIR / "host-setup" / "daemon.json.tpl", args.output_root / "host-setup" / "daemon.json"),
        (
            ROOT_DIR / "host-setup" / "rpa-dummy0.service.tpl",
            args.output_root / "host-setup" / "rpa-dummy0.service",
        ),
        (
            ROOT_DIR / "host-setup" / "haproxy.service.tpl",
            args.output_root / "host-setup" / "haproxy.service",
        ),
        (ROOT_DIR / "haproxy" / "haproxy.cfg.tpl", args.output_root / "haproxy" / "haproxy.cfg"),
        (
            ROOT_DIR / "authentik" / "blueprints" / "10-openmanager-hub.yaml.tpl",
            args.output_root / "authentik" / "blueprints" / "10-openmanager-hub.yaml",
        ),
    ]

    rendered_count = 0
    for tpl_path, out_path in template_pairs:
        if tpl_path.exists():
            render_template(tpl_path, out_path, env, blocks)
            rendered_count += 1

    print(f"[OK] Successfully rendered {rendered_count} configuration file(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
