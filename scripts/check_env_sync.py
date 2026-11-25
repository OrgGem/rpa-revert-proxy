#!/usr/bin/env python3
"""Validate and synchronize .env against .env.example across Dev, Test, and Prod flows."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
ENV_EXAMPLE_PATH = ROOT_DIR / ".env.example"
ENV_PATH = ROOT_DIR / ".env"

KEY_VALUE_RE = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$")
TEMPLATE_VAR_RE = re.compile(r"(?<!\$)\$\{([A-Z][A-Z0-9_]*)(?::-[^}]*)?\}")
PYTHON_ENV_RE = re.compile(r'os\.environ(?:\.get)?\(\s*["\']([A-Z][A-Z0-9_]*)["\']')

PROJECT_VAR_PREFIXES = (
    "DEPLOY_MODE",
    "NODE_",
    "TZ",
    "HOST_",
    "DUMMY_",
    "MGMT_",
    "HAPROXY_",
    "OUTBOUND_",
    "AUTHENTIK_",
    "OPENMANAGER_",
    "APP_",
    "LOCAL_IDP_",
)
# Container-native runtime env names mapped inside Compose/scripts (not top-level .env schema keys)
KNOWN_RUNTIME_ONLY_VARS = {
    "AUTHENTIK_TOKEN",
    "HAPROXY_CONTAINER_NAME",
}
SECRET_KEY_SUFFIXES = ("_TOKEN", "_PASSWORD", "_SECRET", "_SECRET_KEY")
VALID_DEPLOY_MODES = {"local-all-in-one", "prod-hub", "prod-satellite"}


def is_project_schema_var(name: str) -> bool:
    if name in KNOWN_RUNTIME_ONLY_VARS:
        return False
    return name.startswith(PROJECT_VAR_PREFIXES)


def parse_env_file(path: Path) -> dict[str, str]:
    """Parse KEY=VALUE pairs preserving insertion order."""
    result: dict[str, str] = {}
    if not path.exists():
        return result
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = KEY_VALUE_RE.match(raw_line)
        if match:
            key, val = match.group(1), match.group(2)
            if len(val) >= 2 and val[0] == val[-1] and val[0] in {"'", '"'}:
                val = val[1:-1]
            result[key] = val
    return result


def enforce_secure_permissions(path: Path) -> None:
    """Enforce chmod 0600 on POSIX systems so secrets are never world/group-readable."""
    if os.name == "posix" and path.exists():
        os.chmod(path, 0o600)


def collect_referenced_vars() -> dict[str, list[str]]:
    """Scan Compose, templates, Blueprints, shell scripts, and mock-app for ${VAR} references."""
    refs: dict[str, list[str]] = {}

    def record(var_name: str, rel_path: str) -> None:
        refs.setdefault(var_name, [])
        if rel_path not in refs[var_name]:
            refs[var_name].append(rel_path)

    # 1. Declarative Compose & .tpl files: ALL ${VAR} references must exist in .env.example
    strict_patterns = [
        "docker-compose*.yml",
        "docker-compose*.yaml",
        "haproxy/*.tpl",
        "host-setup/*.tpl",
        "authentik/blueprints/*.tpl",
    ]
    for pattern in strict_patterns:
        for file_path in sorted(ROOT_DIR.glob(pattern)):
            rel = file_path.relative_to(ROOT_DIR).as_posix()
            for match in TEMPLATE_VAR_RE.finditer(file_path.read_text(encoding="utf-8")):
                var_name = match.group(1)
                if var_name not in KNOWN_RUNTIME_ONLY_VARS:
                    record(var_name, rel)

    # 2. Shell scripts (*.sh) & skills (*.md): check project-prefixed ${VAR} references
    scoped_patterns = [
        "scripts/*.sh",
        "host-setup/*.sh",
        "tests/*.sh",
        ".agents/skills/*/*.md",
    ]
    for pattern in scoped_patterns:
        for file_path in sorted(ROOT_DIR.glob(pattern)):
            rel = file_path.relative_to(ROOT_DIR).as_posix()
            for match in TEMPLATE_VAR_RE.finditer(file_path.read_text(encoding="utf-8")):
                var_name = match.group(1)
                if is_project_schema_var(var_name):
                    record(var_name, rel)

    # 3. Mock-app Python files: check project-prefixed os.environ lookups
    for file_path in sorted(ROOT_DIR.glob("mock-app/*.py")):
        rel = file_path.relative_to(ROOT_DIR).as_posix()
        for match in PYTHON_ENV_RE.finditer(file_path.read_text(encoding="utf-8")):
            var_name = match.group(1)
            if is_project_schema_var(var_name):
                record(var_name, rel)

    return refs


def sync_env_from_example(example_vars: dict[str, str], env_vars: dict[str, str]) -> tuple[int, int]:
    """Synchronize .env with .env.example: add missing keys, archive removed keys, enforce 0600."""
    if not ENV_PATH.exists():
        content = ENV_EXAMPLE_PATH.read_text(encoding="utf-8").replace("\r\n", "\n")
        ENV_PATH.write_bytes(content.encode("utf-8"))
        enforce_secure_permissions(ENV_PATH)
        print(f"[SYNC] Initialized {ENV_PATH.name} from {ENV_EXAMPLE_PATH.name} (mode 0600 on POSIX).")
        return len(example_vars), 0

    added_keys = [k for k in example_vars if k not in env_vars]
    removed_keys = [k for k in env_vars if k not in example_vars]

    # Rebuild .env following .env.example structure while preserving existing values
    rebuilt_lines: list[str] = []
    for raw_line in ENV_EXAMPLE_PATH.read_text(encoding="utf-8").splitlines():
        match = KEY_VALUE_RE.match(raw_line)
        if match:
            key = match.group(1)
            val = env_vars.get(key, example_vars[key])
            rebuilt_lines.append(f"{key}={val}")
        else:
            rebuilt_lines.append(raw_line)

    if removed_keys:
        rebuilt_lines.append("")
        rebuilt_lines.append("# --- Archived deprecated keys removed from .env.example ---")
        for old_key in removed_keys:
            rebuilt_lines.append(f"# [DEPRECATED] {old_key}={env_vars[old_key]}")

    ENV_PATH.write_bytes(("\n".join(rebuilt_lines) + "\n").encode("utf-8"))
    enforce_secure_permissions(ENV_PATH)
    print(
        f"[SYNC] Synchronized .env: +{len(added_keys)} added, -{len(removed_keys)} archived, "
        f"existing values preserved."
    )
    return len(added_keys), len(removed_keys)


def is_secret_key(key: str) -> bool:
    return key.endswith(SECRET_KEY_SUFFIXES)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check and sync environment variables between .env.example, .env, and codebase."
    )
    parser.add_argument(
        "--sync",
        action="store_true",
        help="Create or synchronize .env with .env.example (adds new keys, archives stale keys, sets 0600).",
    )
    args = parser.parse_args()

    errors: list[str] = []
    warnings: list[str] = []

    if not ENV_EXAMPLE_PATH.exists():
        print("[FAIL] Missing .env.example at repository root.", file=sys.stderr)
        return 1

    example_vars = parse_env_file(ENV_EXAMPLE_PATH)
    env_vars = parse_env_file(ENV_PATH)

    if args.sync:
        sync_env_from_example(example_vars, env_vars)
        env_vars = parse_env_file(ENV_PATH)

    if not ENV_PATH.exists():
        errors.append("Missing .env file (run `python scripts/check_env_sync.py --sync` to initialize).")
    elif os.name == "posix":
        file_mode = ENV_PATH.stat().st_mode & 0o777
        if file_mode & 0o077:
            errors.append(
                f"Insecure permissions on .env ({oct(file_mode)}): group/other permissions must be 0 "
                f"(run `chmod 0600 .env` or `python scripts/check_env_sync.py --sync`)."
            )

    # 1. Check references across Compose, templates, scripts, skills & mock-app
    referenced_vars = collect_referenced_vars()
    for var_name, files in sorted(referenced_vars.items()):
        if var_name not in example_vars:
            errors.append(
                f"Undocumented variable `${{{var_name}}}` used in [{', '.join(files)}] "
                f"but missing from .env.example."
            )

    # 2. Check key parity between .env.example and .env
    if ENV_PATH.exists():
        missing_in_env = [k for k in example_vars if k not in env_vars]
        extra_in_env = [k for k in env_vars if k not in example_vars]
        if missing_in_env:
            errors.append(
                f"Keys present in .env.example but missing in .env: {', '.join(missing_in_env)} "
                f"(run with --sync)."
            )
        if extra_in_env:
            errors.append(
                f"Unregistered/stale keys present in .env but missing in .env.example: "
                f"{', '.join(extra_in_env)} (run with --sync to archive)."
            )

    # 3. Check Zero-Secret policy in .env.example
    for key, val in example_vars.items():
        if is_secret_key(key) and not val.startswith("CHANGE_ME_"):
            errors.append(
                f"Secret hygiene violation in .env.example: `{key}` must use placeholder "
                f"`CHANGE_ME_{key}` (found `{val}`)."
            )

    # 4. Check pinned tags & mode-specific invariants
    for source_name, mapping in ((".env.example", example_vars), (".env", env_vars)):
        if not mapping:
            continue
        for tag_key in ("AUTHENTIK_TAG", "OPENMANAGER_TAG"):
            tag_val = mapping.get(tag_key, "").strip()
            if not tag_val or tag_val.lower() == "latest":
                errors.append(
                    f"Invalid {tag_key} in {source_name}: `{tag_val}` (must pin exact version, never `latest`)."
                )

    if env_vars:
        mode = env_vars.get("DEPLOY_MODE", "")
        if mode not in VALID_DEPLOY_MODES:
            errors.append(
                f"Invalid DEPLOY_MODE `{mode}` in .env (expected one of: {', '.join(sorted(VALID_DEPLOY_MODES))})."
            )
        elif mode in {"prod-hub", "prod-satellite"}:
            if env_vars.get("AUTHENTIK_INSECURE", "").lower() == "true":
                errors.append(
                    f"Production safety violation: AUTHENTIK_INSECURE cannot be `true` when DEPLOY_MODE={mode}."
                )
            if env_vars.get("OPENMANAGER_ALLOW_AGENT_SELF_UPGRADE", "false").lower() == "true":
                errors.append(
                    "Production safety violation: OPENMANAGER_ALLOW_AGENT_SELF_UPGRADE must be `false`."
                )
            # Validate required secrets for the active production role
            hub_only_prefixes = (
                "AUTHENTIK_OUTPOST_TOKEN",
                "OPENMANAGER_POSTGRES_PASSWORD",
                "OPENMANAGER_SECRET_KEY",
                "LOCAL_IDP_POSTGRES_PASSWORD",
                "LOCAL_IDP_SECRET_KEY",
            )
            sat_only_prefixes = ("OPENMANAGER_AGENT_TOKEN",)
            for key, val in env_vars.items():
                if key.startswith("LOCAL_IDP_BOOTSTRAP_"):
                    continue
                if mode == "prod-satellite" and key.startswith(hub_only_prefixes):
                    continue
                if mode == "prod-hub" and key.startswith(sat_only_prefixes):
                    continue
                if val.startswith("CHANGE_ME_") or val.startswith("dev_only_"):
                    errors.append(
                        f"Production secret violation: `{key}` still has placeholder/dev value in .env "
                        f"under DEPLOY_MODE={mode}."
                    )

    for warning in warnings:
        print(f"[WARN] {warning}")

    if errors:
        for err in errors:
            print(f"[FAIL] {err}", file=sys.stderr)
        print(f"\nEnvironment check FAILED with {len(errors)} error(s).", file=sys.stderr)
        return 1

    print(
        f"[OK] Environment sync verified: {len(example_vars)} schema keys aligned, "
        f"{len(referenced_vars)} codebase reference(s) covered, DEPLOY_MODE={env_vars.get('DEPLOY_MODE')}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
