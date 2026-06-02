#!/usr/bin/env bash
# Idempotently add a web redirect URI to an Azure AD / Entra app registration via Microsoft Graph.
# Requires a separate automation app (not the connector app) with Application.ReadWrite.All.
#
# Usage:
#   TENANT_ID=... GRAPH_CLIENT_ID=... GRAPH_CLIENT_SECRET=... \
#   TARGET_APP_ID=<MS_CLIENT_ID> REDIRECT_URI=https://.../callback \
#   ./sync-microsoft-oauth-redirect-uri.sh
#
# Optional: DRY_RUN=true prints actions without PATCH.
set -euo pipefail

TENANT_ID="${TENANT_ID:?TENANT_ID is required}"
GRAPH_CLIENT_ID="${GRAPH_CLIENT_ID:?GRAPH_CLIENT_ID is required}"
GRAPH_CLIENT_SECRET="${GRAPH_CLIENT_SECRET:?GRAPH_CLIENT_SECRET is required}"
TARGET_APP_ID="${TARGET_APP_ID:?TARGET_APP_ID is required (connector MS_CLIENT_ID)}"
REDIRECT_URI="${REDIRECT_URI:?REDIRECT_URI is required}"
DRY_RUN="${DRY_RUN:-false}"

TOKEN_JSON="$(mktemp)"
APP_JSON="$(mktemp)"
PATCH_JSON="$(mktemp)"
trap 'rm -f "${TOKEN_JSON}" "${APP_JSON}" "${PATCH_JSON}"' EXIT

code="$(
  curl -sS -o "${TOKEN_JSON}" -w '%{http_code}' -X POST \
    "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
    -d "client_id=${GRAPH_CLIENT_ID}" \
    -d "client_secret=${GRAPH_CLIENT_SECRET}" \
    -d "scope=https%3A%2F%2Fgraph.microsoft.com%2F.default" \
    -d "grant_type=client_credentials"
)"
if [[ "${code}" != "200" ]]; then
  echo "FAIL: token request HTTP ${code}" >&2
  cat "${TOKEN_JSON}" >&2
  exit 1
fi

TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' < "${TOKEN_JSON}")"

filter="appId eq '${TARGET_APP_ID}'"
encoded_filter="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "${filter}")"
code="$(
  curl -sS -o "${APP_JSON}" -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://graph.microsoft.com/v1.0/applications?\$filter=${encoded_filter}&\$select=id,appId,web"
)"
if [[ "${code}" != "200" ]]; then
  echo "FAIL: list applications HTTP ${code}" >&2
  cat "${APP_JSON}" >&2
  if [[ "${code}" == "403" ]]; then
    cat >&2 <<EOF

Likely cause: admin consent is NOT granted for Application.ReadWrite.All on the
automation app (GRAPH_CLIENT_ID=${GRAPH_CLIENT_ID}), not the connector (TARGET_APP_ID).

Portal: ContentIQ-OAuth-Redirect-Automation → API permissions → Microsoft Graph →
  Application.ReadWrite.All → must show "Granted for ..." (green check).
Delegated User.Read does NOT fix this.

CLI (admin): ./ansible/scripts/grant-azure-graph-admin-consent.sh  (after az login)

Manual unblock: Azure Portal → onedrive-connector (TARGET_APP_ID) → Authentication →
  add REDIRECT_URI manually, then retry Connect Microsoft in ContentIQ.
EOF
  fi
  exit 1
fi

python3 - <<'PY' "${APP_JSON}" "${REDIRECT_URI}" "${TOKEN}" "${DRY_RUN}" "${TARGET_APP_ID}" "${PATCH_JSON}"
import json
import sys
import urllib.error
import urllib.request

app_json, redirect_uri, token, dry_run, target_app_id, patch_json = sys.argv[1:7]
data = json.loads(open(app_json, encoding="utf-8").read())
apps = data.get("value") or []
if not apps:
    print(f"FAIL: no application found with appId={target_app_id}", file=sys.stderr)
    sys.exit(1)

app = apps[0]
object_id = app["id"]
existing = list((app.get("web") or {}).get("redirectUris") or [])
if redirect_uri in existing:
    print(f"OK: redirect URI already registered for appId={target_app_id}")
    sys.exit(0)

merged = existing + [redirect_uri]
body = {"web": {"redirectUris": merged}}
open(patch_json, "w", encoding="utf-8").write(json.dumps(body))

if dry_run.lower() in ("1", "true", "yes"):
    print(f"DRY_RUN: would PATCH applications/{object_id} adding {redirect_uri}")
    sys.exit(0)

req = urllib.request.Request(
    f"https://graph.microsoft.com/v1.0/applications/{object_id}",
    data=json.dumps(body).encode("utf-8"),
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    },
    method="PATCH",
)
try:
    with urllib.request.urlopen(req) as resp:
        if resp.status not in (200, 204):
            print(f"FAIL: PATCH HTTP {resp.status}", file=sys.stderr)
            sys.exit(1)
except urllib.error.HTTPError as exc:
    print(f"FAIL: PATCH HTTP {exc.code}", file=sys.stderr)
    print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
    sys.exit(1)

print(f"OK: registered redirect URI for appId={target_app_id}")
PY
