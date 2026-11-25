#!/usr/bin/env python3
"""Validate and synchronize .env against .env.example across Dev, Test, and Prod flows."""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
ENV_EXAMPLE_PATH = ROOT_DIR / ".env.example"
ENV_PATH = ROOT_DIR / ".env"

KEY_VALUE_RE = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$")
TEMPLATE_VAR_RE = re.compile(r"(?<!\$)\$\{([A-Z][A-Z0-9_]*)(?::-[^}]*)?\}")
SECRET_KEY_SUFFIXES = ("_TOKEN", "_PASSWORD", "_SECRET", "_SECRET_KEY")
VALID_DEPLOY_MODES = {"local-all-in-one", "prod-satellite", "prod-hub"}


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


def collect_referenced_vars() -> dict[str, list[str]]:
    """Find ${VAR} references across declarative Compose and .tpl files."""
    refs: dict[str, list[str]] = {}
    scan_patterns = [
        "docker-compose*.yml",
        "docker-compose*.yaml",
        "haproxy/*.tpl",
        "host-setup/*.tpl",
    ]
    for pattern in scan_patterns:
        for file_path in sorted(ROOT_DIR.glob(pattern)):
            rel = file_path.relative_to(ROOT_DIR).as_posix()
            content = file_path.read_text(encoding="utf-8")
            for match in TEMPLATE_VAR_RE.finditer(content):
                var_name = match.group(1)
                refs.setdefault(var_name, [])
                if rel not in refs[var_name]:
                    refs[var_name].append(rel)
    return refs


def sync_env_from_example(example_vars: dict[str, str], env_vars: dict[str, str]) -> int:
    """Create .env or append missing variables from .env.example without overwriting existing keys."""
    if not ENV_PATH.exists():
        shutil.copyfile(ENV_EXAMPLE_PATH, ENV_PATH)
        print(f"[SYNC] Created {ENV_PATH.name} from {ENV_EXAMPLE_PATH.name}.")
        return len(example_vars)

    missing_keys = [k for k in example_vars if k not in env_vars]
    if not missing_keys:
        print("[SYNC] .env already contains all keys from .env.example.")
        return 0

    lines_to_append = [
        "",
        "# --- Auto-synced missing keys from .env.example ---",
    ]
    for key in missing_keys:
        lines_to_append.append(f"{key}={example_vars[key]}")

    with ENV_PATH.open("a", encoding="utf-8") as fh:
        fh.write("\n".join(lines_to_append) + "\n")

    print(f"[SYNC] Appended {len(missing_keys)} missing key(s) to .env: {', '.join(missing_keys)}")
    return len(missing_keys)


def is_secret_key(key: str) -> bool:
    return key.endswith(SECRET_KEY_SUFFIXES)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check and sync environment variables between .env.example, .env, and templates."
    )
    parser.add_argument(
        "--sync",
        action="store_true",
        help="Automatically create .env or append missing keys from .env.example.",
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

    # 1. Check references in Compose & templates against .env.example
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
                f"Unregistered keys present in .env but missing in .env.example: {', '.join(extra_in_env)}."
            )

    # 3. Check Zero-Secret policy in .env.example
    for key, val in example_vars.items():
        if is_secret_key(key) and not val.startswith("CHANGE_ME_"):
            errors.append(
                f"Secret hygiene violation in .env.example: `{key}` must use placeholder "
                f"`CHANGE_ME_{key}` (found `{val}`)."
            )

    # 4. Check architectural & mode-specific invariants
    for source_name, mapping in ((".env.example", example_vars), (".env", env_vars)):
        if not mapping:
            continue
        tag = mapping.get("AUTHENTIK_TAG", "").strip()
        if not tag or tag.lower() == "latest":
            errors.append(
                f"Invalid AUTHENTIK_TAG in {source_name}: `{tag}` (must pin exact version, never `latest`)."
            )

    if env_vars:
        mode = env_vars.get("DEPLOY_MODE", "")
        if mode not in VALID_DEPLOY_MODES:
            errors.append(
                f"Invalid DEPLOY_MODE `{mode}` in .env (expected one of: {', '.join(sorted(VALID_DEPLOY_MODES))})."
            )
        elif mode in {"prod-satellite", "prod-hub"}:
            if env_vars.get("AUTHENTIK_INSECURE", "").lower() == "true":
                errors.append(
                    f"Production safety violation: AUTHENTIK_INSECURE cannot be `true` when DEPLOY_MODE={mode}."
                )
            for key, val in env_vars.items():
                if key.startswith("LOCAL_IDP_"):
                    continue
                if val.startswith("CHANGE_ME_") or val.startswith("dev_only_"):
                    errors.append(
                        f"Production secret violation: `{key}` still has placeholder/dev value in .env "
                        f"under DEPLOY_MODE={mode}."
                    )
            if "*.local.test" in env_vars.get("AUTHENTIK_DOMAIN", "") or env_vars.get(
                "AUTHENTIK_DOMAIN", ""
            ).endswith(".local.test"):
                warnings.append(
                    f"AUTHENTIK_DOMAIN (`{env_vars.get('AUTHENTIK_DOMAIN')}`) still uses `.local.test` "
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
        f"{len(referenced_vars)} template reference(s) covered, DEPLOY_MODE={env_vars.get('DEPLOY_MODE')}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
