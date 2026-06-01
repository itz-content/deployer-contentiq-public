#!/usr/bin/env python3
"""Forward Google/Box OAuth callbacks from a fixed platform hostname to reservation backends.

The ContentIQ backend must encode the reservation backend origin in OAuth ``state``, e.g.:
  base64url(JSON({"backend_origin": "https://api-contentiq-....techzone.ibm.com"}))

Register only this proxy's public URLs in Google Cloud Console and Box Developer Console.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CALLBACK_PATHS = frozenset(
    {
        "/api/connections/googledrive/auth/google/callback",
        "/api/connections/box/auth/box/callback",
    }
)


def _decode_json_blob(raw: str) -> dict | None:
    for payload in (raw, raw + "===", raw + "=="):
        for decoder in (base64.urlsafe_b64decode, base64.b64decode):
            try:
                data = json.loads(decoder(payload.encode("ascii")))
            except Exception:
                continue
            if isinstance(data, dict):
                return data
    try:
        data = json.loads(raw)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def backend_from_state(state: str) -> str | None:
    if not state:
        return None

    data = _decode_json_blob(state)
    if data:
        for key in ("backend_origin", "backend", "return_backend", "return_to"):
            val = data.get(key)
            if val:
                origin = str(val).strip().rstrip("/")
                if origin.startswith("http://") or origin.startswith("https://"):
                    return origin

    if ":" in state:
        tail = state.rsplit(":", 1)[-1].strip().rstrip("/")
        if tail.startswith("http://") or tail.startswith("https://"):
            return tail

    return None


class OAuthCallbackProxyHandler(BaseHTTPRequestHandler):
    server_version = "ContentIQOAuthCallbackProxy/1.0"

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        if parsed.path not in CALLBACK_PATHS:
            self.send_error(404, "Unknown callback path")
            return

        qs = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        state = (qs.get("state") or [""])[0]
        backend = backend_from_state(state)
        if not backend:
            self.send_error(
                400,
                "OAuth state did not include reservation backend origin "
                "(expected backend_origin in base64 JSON state).",
            )
            return

        target = f"{backend}{parsed.path}"
        if parsed.query:
            target = f"{target}?{parsed.query}"

        self.send_response(302)
        self.send_header("Location", target)
        self.end_headers()

    def log_message(self, fmt: str, *args) -> None:
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    HTTPServer(("0.0.0.0", port), OAuthCallbackProxyHandler).serve_forever()


if __name__ == "__main__":
    main()
