#!/usr/bin/env python3
"""Forward OAuth callbacks from a fixed platform hostname to reservation backends.

The ContentIQ backend signs an envelope in OAuth ``state``:
  base64url(compact-json).base64url(hmac-sha256)

The HMAC secret must be shared with the backend. The target origin must also
match OAUTH_CALLBACK_ALLOWED_BACKEND_ORIGINS or one of the suffixes in
OAUTH_CALLBACK_ALLOWED_BACKEND_SUFFIXES.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CALLBACK_PATHS = frozenset(
    {
        "/api/connections/googledrive/auth/google/callback",
        "/api/connections/box/auth/box/callback",
        "/api/connections/microsoft/auth/microsoft/callback",
    }
)


def _b64_decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def _normalize_origin(value: str) -> str | None:
    parsed = urllib.parse.urlparse(str(value or "").strip())
    if parsed.scheme.lower() not in {"http", "https"} or not parsed.netloc:
        return None
    if (
        parsed.username
        or parsed.password
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        return None
    return f"{parsed.scheme.lower()}://{parsed.netloc.lower()}".rstrip("/")


def _allowed_backend(origin: str) -> bool:
    exact = {
        item.strip().rstrip("/").lower()
        for item in os.getenv("OAUTH_CALLBACK_ALLOWED_BACKEND_ORIGINS", "").split(",")
        if item.strip()
    }
    if origin.lower() in exact:
        return True

    hostname = urllib.parse.urlparse(origin).hostname or ""
    suffixes = {
        item.strip().lower().lstrip(".")
        for item in os.getenv("OAUTH_CALLBACK_ALLOWED_BACKEND_SUFFIXES", "").split(",")
        if item.strip()
    }
    return any(
        hostname == suffix or hostname.endswith(f".{suffix}")
        for suffix in suffixes
    )


def backend_from_state(state: str) -> str | None:
    if not state or not os.getenv("OAUTH_CALLBACK_STATE_SECRET"):
        return None
    try:
        encoded_body, encoded_signature = state.split(".", 1)
        expected = hmac.new(
            os.environ["OAUTH_CALLBACK_STATE_SECRET"].encode("utf-8"),
            encoded_body.encode("ascii"),
            hashlib.sha256,
        ).digest()
        supplied = _b64_decode(encoded_signature)
        if not hmac.compare_digest(expected, supplied):
            return None
        data = json.loads(_b64_decode(encoded_body).decode("utf-8"))
        if not isinstance(data, dict) or data.get("v") != 1:
            return None
        if int(data.get("exp", 0)) < int(time.time()):
            return None
        origin = _normalize_origin(data.get("backend_origin", ""))
        if not origin or not _allowed_backend(origin):
            return None
        return origin
    except (binascii.Error, ValueError, TypeError, UnicodeError, json.JSONDecodeError):
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
