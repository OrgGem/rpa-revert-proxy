#!/usr/bin/env python3
"""Lightweight zero-dependency Mock Service A for Inbound HTTP/2 & Outbound Egress Gates."""

from __future__ import annotations

import json
import os
import socket
import ssl
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
DEFAULT_OUTBOUND_DOMAIN = os.environ.get("APP_TEST_OUTBOUND_DOMAIN", "httpbin.org")


class MockAppHandler(BaseHTTPRequestHandler):
    server_version = "RPA-MockServiceA/1.1"

    def _send_json(self, status_code: int, payload: dict) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/healthz":
            self._send_json(200, {"status": "ok", "service": "mock-service-a"})
            return

        if parsed.path in {"/", "/whoami"}:
            headers_dict = {k: v for k, v in self.headers.items()}
            self._send_json(
                200,
                {
                    "service": "mock-service-a",
                    "path": parsed.path,
                    "client_socket_ip": self.client_address[0],
                    "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                    "x_forwarded_proto": self.headers.get("X-Forwarded-Proto"),
                    "host": self.headers.get("Host"),
                    "headers": headers_dict,
                },
            )
            return

        if parsed.path == "/test-outbound":
            domain = query.get("domain", [DEFAULT_OUTBOUND_DOMAIN])[0]
            path = query.get("path", ["/get"])[0]
            if not path.startswith("/"):
                path = "/" + path
            url = f"https://{domain}{path}"
            start = time.monotonic()
            try:
                resolved_ips = sorted({item[4][0] for item in socket.getaddrinfo(domain, 443, socket.AF_INET)})
                ctx = ssl.create_default_context()
                with socket.create_connection((domain, 443), timeout=10) as raw_sock:
                    with ctx.wrap_socket(raw_sock, server_hostname=domain) as tls_sock:
                        peer_cert = tls_sock.getpeercert()
                        tls_version = tls_sock.version()
                req = urllib.request.Request(url, headers={"User-Agent": "RPA-MockServiceA/1.1"})
                with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
                    status = resp.status
                elapsed_ms = round((time.monotonic() - start) * 1000, 2)
                self._send_json(
                    200,
                    {
                        "ok": True,
                        "target_url": url,
                        "resolved_ipv4": resolved_ips,
                        "http_status": status,
                        "tls_version": tls_version,
                        "peer_cert_subject": peer_cert.get("subject", []),
                        "peer_cert_issuer": peer_cert.get("issuer", []),
                        "latency_ms": elapsed_ms,
                    },
                )
            except Exception as exc:
                self._send_json(
                    502,
                    {"ok": False, "target_url": url, "error_type": type(exc).__name__, "error": str(exc)},
                )
            return

        if parsed.path == "/test-egress-bypass":
            # Gate EGRESS-01: verify unlisted SNI, direct public IP (1.1.1.1:443), and IPv6 are ALL blocked
            gateway_ip = query.get("gateway_ip", ["10.254.254.1"])[0]
            sni = query.get("sni", ["forbidden-unlisted.example.org"])[0]
            results: dict[str, bool] = {}

            # 1. Unlisted SNI via HAProxy Outbound
            try:
                ctx = ssl.create_default_context()
                with socket.create_connection((gateway_ip, 443), timeout=3) as raw_sock:
                    with ctx.wrap_socket(raw_sock, server_hostname=sni):
                        pass
                results["unlisted_sni_blocked"] = False
            except Exception:
                results["unlisted_sni_blocked"] = True

            # 2. Direct external IP literal bypass (1.1.1.1:443 without proxy)
            try:
                with socket.create_connection(("1.1.1.1", 443), timeout=3):
                    pass
                results["direct_ip_blocked"] = False
            except Exception:
                results["direct_ip_blocked"] = True

            # 3. Direct IPv6 literal bypass ([2606:4700:4700::1111]:443)
            try:
                sock6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
                sock6.settimeout(3)
                sock6.connect(("2606:4700:4700::1111", 443))
                sock6.close()
                results["ipv6_egress_blocked"] = False
            except Exception:
                results["ipv6_egress_blocked"] = True

            all_blocked = all(results.values())
            self._send_json(
                200 if all_blocked else 500,
                {"ok": all_blocked, "checks": results},
            )
            return

        self._send_json(404, {"error": "not_found", "path": parsed.path})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), MockAppHandler)
    print(f"[INFO] Mock Service A listening on 0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
