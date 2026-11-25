#!/usr/bin/env python3
"""Automated offline test suite verifying env sync, 3-mode template rendering & Zero-Nginx security."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
CHECK_SCRIPT = ROOT_DIR / "scripts" / "check_env_sync.py"
RENDER_SCRIPT = ROOT_DIR / "scripts" / "render_configs.py"


class ProjectIntegrityTests(unittest.TestCase):
    def test_01_env_sync_gate_passes_across_entire_codebase(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(CHECK_SCRIPT)],
            cwd=str(ROOT_DIR),
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, f"check_env_sync.py failed:\n{proc.stderr}\n{proc.stdout}")
        self.assertIn("[OK] Environment sync verified", proc.stdout)

    def test_02_render_local_all_in_one_mode(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_root = Path(tmp)
            proc = subprocess.run(
                [
                    sys.executable,
                    str(RENDER_SCRIPT),
                    "--skip-env-check",
                    "--env-file",
                    str(ROOT_DIR / ".env"),
                    "--output-root",
                    str(out_root),
                ],
                cwd=str(ROOT_DIR),
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, f"render_configs.py failed:\n{proc.stderr}")

            # Verify daemon.json IPv4 + IPv6 zero-forwarding invariants (FR-01)
            daemon_cfg = json.loads((out_root / "host-setup" / "daemon.json").read_text(encoding="utf-8"))
            self.assertIs(daemon_cfg["ip-forward"], False)
            self.assertIs(daemon_cfg["ipv6"], False)
            self.assertEqual(daemon_cfg["ip"], "127.0.0.1")
            self.assertIs(daemon_cfg["userland-proxy"], True)
            self.assertEqual(daemon_cfg["host-gateway-ip"], "10.254.254.1")

            # Verify haproxy.cfg structure & partial-merge compatibility
            hap_cfg = (out_root / "haproxy" / "haproxy.cfg").read_text(encoding="utf-8")
            self.assertNotIn("0.0.0.0:443", hap_cfg)
            self.assertIn("master-worker", hap_cfg)
            self.assertIn("hard-stop-after 60s", hap_cfg)
            self.assertIn("user haproxy", hap_cfg)
            self.assertIn("stats socket /var/run/haproxy/admin.sock", hap_cfg)
            self.assertIn("listen prometheus_exporter", hap_cfg)
            # `resolvers host_dns` MUST appear before `defaults` so haproxy-agent preserves it
            self.assertLess(hap_cfg.index("resolvers host_dns"), hap_cfg.index("\ndefaults\n"))
            # Dual-path Hub + Satellite backends present in all-in-one mode
            self.assertIn("backend be_openmanager_sso_proxy", hap_cfg)
            self.assertIn("backend be_openmanager_agent_api", hap_cfg)
            self.assertIn("backend be_authentik_idp", hap_cfg)
            self.assertIn("backend be_business_app", hap_cfg)
            self.assertIn("backend be_out_authentik_main", hap_cfg)
            self.assertIn("server srv_httpbin_org httpbin.org:443", hap_cfg)

            # Verify Authentik Blueprint points to Zero-Nginx openmanager-router
            bp_text = (out_root / "authentik" / "blueprints" / "10-openmanager-hub.yaml").read_text(encoding="utf-8")
            self.assertIn('internal_host: "http://openmanager-router:8080"', bp_text)
            self.assertIn("internal_host_ssl_validation: false", bp_text)
            self.assertIn("default-provider-authorization-implicit-consent", bp_text)

    def test_03_render_prod_hub_and_prod_satellite_separation(self) -> None:
        base_env = (ROOT_DIR / ".env").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)

            # Check prod-satellite mode: NO local IdP or OpenManager backends
            sat_env_file = tmp_path / ".env.sat"
            sat_env_file.write_text(
                re.sub(r"^DEPLOY_MODE=.*$", "DEPLOY_MODE=prod-satellite", base_env, flags=re.MULTILINE),
                encoding="utf-8",
            )
            sat_out = tmp_path / "sat_out"
            proc_sat = subprocess.run(
                [
                    sys.executable,
                    str(RENDER_SCRIPT),
                    "--skip-env-check",
                    "--env-file",
                    str(sat_env_file),
                    "--output-root",
                    str(sat_out),
                ],
                cwd=str(ROOT_DIR),
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc_sat.returncode, 0, proc_sat.stderr)
            sat_hap = (sat_out / "haproxy" / "haproxy.cfg").read_text(encoding="utf-8")
            self.assertNotIn("be_openmanager_sso_proxy", sat_hap)
            self.assertNotIn("be_authentik_idp", sat_hap)
            self.assertIn("be_business_app", sat_hap)

            # Check prod-hub mode: Hub routes present, business app omitted by default
            hub_env_file = tmp_path / ".env.hub"
            hub_env_file.write_text(
                re.sub(r"^DEPLOY_MODE=.*$", "DEPLOY_MODE=prod-hub", base_env, flags=re.MULTILINE),
                encoding="utf-8",
            )
            hub_out = tmp_path / "hub_out"
            proc_hub = subprocess.run(
                [
                    sys.executable,
                    str(RENDER_SCRIPT),
                    "--skip-env-check",
                    "--env-file",
                    str(hub_env_file),
                    "--output-root",
                    str(hub_out),
                ],
                cwd=str(ROOT_DIR),
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc_hub.returncode, 0, proc_hub.stderr)
            hub_hap = (hub_out / "haproxy" / "haproxy.cfg").read_text(encoding="utf-8")
            self.assertIn("be_openmanager_sso_proxy", hub_hap)
            self.assertIn("be_openmanager_agent_api", hub_hap)
            self.assertNotIn("be_business_app", hub_hap)

    def test_04_compose_zero_nginx_and_loopback_security(self) -> None:
        compose_files = (
            "docker-compose.yml",
            "docker-compose.hub.yml",
            "docker-compose.mock-app.yml",
        )
        for compose_name in compose_files:
            raw_text = (ROOT_DIR / compose_name).read_text(encoding="utf-8")
            non_comment = "\n".join(
                line for line in raw_text.splitlines() if not line.strip().startswith("#")
            )
            self.assertNotIn(":latest", non_comment, f"{compose_name} must never use :latest tags")
            self.assertNotIn("nginx:", non_comment.lower(), f"{compose_name} must contain zero Nginx images")
            self.assertNotIn("docker.sock", non_comment, f"{compose_name} must never mount docker.sock")
            for match in re.finditer(r'^\s*-\s*"([^"]+:\d+)"\s*$', non_comment, flags=re.MULTILINE):
                port_mapping = match.group(1)
                self.assertTrue(
                    port_mapping.startswith("127.0.0.1:"),
                    f"Published port `{port_mapping}` in {compose_name} must bind strictly to 127.0.0.1",
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
