#!/usr/bin/env bash
# Probe whether the current IBM Cloud API key can use Secrets Manager on this instance.
#
#   ./playbooks/scripts/check-ibm-sm-apikey-access.sh
#
# API key resolution (first match wins):
#   IBM_CLOUD_API_KEY / IBM_CLOUD_API_KEY_FILE / IBMCLOUD_API_KEY
#   else kube-system/ibm-secret (when oc works)
#
# Optional env (defaults match tekton/.env.sm.example and deploy.yml):
#   SECRETS_MANAGER_ENDPOINT_URL
#   BACKEND_SECRET_KEY_ID  — used for GET + optional POST probe
#   SM_PROBE_POST=true       — also POST a tiny test version (not recommended on prod)
#   IBM_SM_TLS_VALIDATE      — true (default) or false
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

END="${SECRETS_MANAGER_ENDPOINT_URL:-https://afa20521-cd75-4864-843f-e59fd0ffd49d.us-south.secrets-manager.appdomain.cloud}"
END="${END%/}"
PROBE_SECRET_ID="${BACKEND_SECRET_KEY_ID:-83eec62f-23d7-80d3-de6c-f7aa48c3ec4e}"
IBM_SM_TLS_VALIDATE="${IBM_SM_TLS_VALIDATE:-true}"
OC_BIN="${CONTENTIQ_OC_BINARY:-${OC_BINARY:-oc}}"

# macOS bash 3.2 + set -u: "${empty[@]}" errors; use a helper instead of curl_tls=().
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

print_http_body() {
  local body_file="$1"
  python3 - "$body_file" <<'PY' 2>/dev/null || head -c 2000 "$body_file"
import json, sys
p = sys.argv[1]
raw = open(p, encoding="utf-8", errors="replace").read()
try:
    print(json.dumps(json.loads(raw), indent=2)[:2000])
except Exception:
    print(raw[:2000])
PY
  if [[ -s "$body_file" ]] && [[ "$(wc -c <"$body_file")" -gt 2000 ]]; then
    echo "(truncated; full file was $body_file)"
  fi
}

resolve_api_key || {
  echo "Set IBM_CLOUD_API_KEY or ensure ${OC_BIN} can read kube-system/ibm-secret." >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== 1) IAM token exchange ==="
iam_code="$(sm_curl -sS -o "${TMP}/iam.json" -w '%{http_code}' \
  -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  --data-urlencode "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
  --data-urlencode "apikey=${IBM_CLOUD_API_KEY}")"
echo "HTTP ${iam_code}"
if [[ "${iam_code}" != "200" ]]; then
  print_http_body "${TMP}/iam.json"
  exit 1
fi
TOKEN="$(python3 -c 'import json; print(json.load(open("'"${TMP}/iam.json"'"))["access_token"])')"
echo "IAM OK (token length ${#TOKEN} chars, not printed)."

echo ""
echo "=== 2) Secrets Manager GET secret (read path) ==="
get_url="${END}/api/v2/secrets/${PROBE_SECRET_ID}"
echo "GET ${get_url}"
get_code="$(sm_curl -sS -o "${TMP}/get.json" -w '%{http_code}' \
  -X GET "${get_url}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json")"
echo "HTTP ${get_code}"
print_http_body "${TMP}/get.json"

if [[ "${get_code}" == "403" || "${get_code}" == "401" ]]; then
  echo "" >&2
  echo "This API key cannot read that secret. Common causes:" >&2
  echo "  - Key is a Service ID API key without Secrets Manager access on this instance" >&2
  echo "  - Key is from a different IBM Cloud account than the SM instance owner" >&2
  echo "  - Only Reader role (need at least Reader on the secret group / instance)" >&2
  echo "Grant the identity (user or service ID) IBM Cloud access:" >&2
  echo "  Secrets Manager → your instance → Manage access → Add (Reader for sync, Writer/Manager for push)" >&2
fi

echo ""
if [[ "${SM_PROBE_POST:-}" != "true" ]]; then
  echo "=== 3) POST new version (skipped: SM_PROBE_POST != true) ==="
  exit 0
fi

echo "=== 3) POST new version (SM_PROBE_POST=true; creates a throwaway version) ==="
post_url="${END}/api/v2/secrets/${PROBE_SECRET_ID}/versions"
echo "POST ${post_url}"
probe_payload='{"payload":"contentiq-sm-probe","custom_metadata":{}}'
post_code="$(sm_curl -sS -o "${TMP}/post.json" -w '%{http_code}' \
  -X POST "${post_url}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d "${probe_payload}")"
echo "HTTP ${post_code}"
print_http_body "${TMP}/post.json"

if [[ "${post_code}" == "403" || "${post_code}" == "401" ]]; then
  echo "" >&2
  echo "This API key cannot create secret versions (push). Need Writer or Manager on the instance." >&2
  exit 1
fi
