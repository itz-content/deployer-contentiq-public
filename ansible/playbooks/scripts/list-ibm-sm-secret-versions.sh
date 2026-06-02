#!/usr/bin/env bash
# List recent IBM Secrets Manager versions for ContentIQ backend/RAG secrets.
#
#   cd ansible
#   export IBM_CLOUD_API_KEY='...'   # or rely on kube-system/ibm-secret via oc
#   source tekton/.env.sm            # optional: END + secret UUIDs
#   ./playbooks/scripts/list-ibm-sm-secret-versions.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ -f "${ANSIBLE_ROOT}/tekton/.env.sm" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "${ANSIBLE_ROOT}/tekton/.env.sm"
  set +a
fi

END="${SECRETS_MANAGER_ENDPOINT_URL:-https://afa20521-cd75-4864-843f-e59fd0ffd49d.us-south.secrets-manager.appdomain.cloud}"
END="${END%/}"
BACKEND_SECRET_KEY_ID="${BACKEND_SECRET_KEY_ID:-83eec62f-23d7-80d3-de6c-f7aa48c3ec4e}"
RAG_SECRET_KEY_ID="${RAG_SECRET_KEY_ID:-3520bb5f-9050-8928-e812-67ed3c959fa8}"
IBM_SM_TLS_VALIDATE="${IBM_SM_TLS_VALIDATE:-true}"
OC_BIN="${CONTENTIQ_OC_BINARY:-${OC_BINARY:-oc}}"

sm_curl() {
  if [[ "${IBM_SM_TLS_VALIDATE}" != "true" ]]; then
    curl -k "$@"
  else
    curl "$@"
  fi
}

resolve_api_key() {
  if [[ -n "${IBM_CLOUD_API_KEY:-}" ]]; then
    return 0
  fi
  if [[ -n "${IBM_CLOUD_API_KEY_FILE:-}" && -f "${IBM_CLOUD_API_KEY_FILE}" ]]; then
    IBM_CLOUD_API_KEY="$(<"${IBM_CLOUD_API_KEY_FILE}")"
    IBM_CLOUD_API_KEY="${IBM_CLOUD_API_KEY//$'\r'/}"
    IBM_CLOUD_API_KEY="${IBM_CLOUD_API_KEY//$'\n'/}"
    export IBM_CLOUD_API_KEY
    return 0
  fi
  if [[ -n "${IBMCLOUD_API_KEY:-}" ]]; then
    export IBM_CLOUD_API_KEY="${IBMCLOUD_API_KEY}"
    return 0
  fi
  if command -v "${OC_BIN}" >/dev/null 2>&1; then
    local b64 key
    b64="$("${OC_BIN}" get secret ibm-secret -n kube-system -o jsonpath='{.data.apiKey}' 2>/dev/null)" || return 1
    [[ -n "${b64}" ]] || return 1
    key="$(printf '%s' "${b64}" | base64 -d)" || return 1
    [[ -n "${key}" ]] || return 1
    export IBM_CLOUD_API_KEY="${key}"
    echo "(using API key from kube-system/ibm-secret)" >&2
    return 0
  fi
  return 1
}

list_versions() {
  local label="$1"
  local secret_id="$2"
  local token="$3"
  local out="${TMP}/versions-${secret_id}.json"
  local code
  echo ""
  echo "=== ${label} (${secret_id}) ==="
  code="$(sm_curl -sS -o "${out}" -w '%{http_code}' \
    -X GET "${END}/api/v2/secrets/${secret_id}/versions" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json")"
  echo "HTTP ${code}"
  if [[ "${code}" != "200" ]]; then
    python3 -m json.tool "${out}" 2>/dev/null || cat "${out}"
    return 1
  fi
  python3 - "${out}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
versions = data.get("versions") or data.get("secrets") or []
if not versions and isinstance(data, dict):
    # Some responses nest under metadata
    versions = data.get("metadata", {}).get("versions") or []
if not versions:
    print(json.dumps(data, indent=2)[:3000])
    sys.exit(0)

def sort_key(v):
    return v.get("created_at") or v.get("creation_date") or ""

rows = sorted(versions, key=sort_key, reverse=True)[:10]
print("Latest versions (up to 10, newest first):")
for v in rows:
    vid = v.get("id") or v.get("version_id") or "?"
    created = v.get("created_at") or v.get("creation_date") or "?"
    state = v.get("state") or v.get("version_status") or ""
    extra = (" " + state) if state else ""
    print("  %s  created_at=%s%s" % (vid, created, extra))
PY
}

resolve_api_key || {
  echo "IBM_CLOUD_API_KEY is not set." >&2
  echo "  export IBM_CLOUD_API_KEY='...'" >&2
  echo "  # tekton/.env.sm does NOT include the API key — only instance URL and secret IDs" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Instance: ${END}"
iam_out="${TMP}/iam.json"
iam_code="$(sm_curl -sS -o "${iam_out}" -w '%{http_code}' \
  -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  --data-urlencode "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
  --data-urlencode "apikey=${IBM_CLOUD_API_KEY}")"
if [[ "${iam_code}" != "200" ]]; then
  echo "IAM token exchange failed: HTTP ${iam_code}" >&2
  echo "Check IBM_CLOUD_API_KEY is set and non-empty (curl 400 usually means empty apikey)." >&2
  cat "${iam_out}" >&2
  exit 1
fi
TOKEN="$(python3 -c 'import json; print(json.load(open("'"${iam_out}"'"))["access_token"])')"
echo "IAM OK"

list_versions "Backend" "${BACKEND_SECRET_KEY_ID}" "${TOKEN}" || true
list_versions "RAG" "${RAG_SECRET_KEY_ID}" "${TOKEN}" || true
