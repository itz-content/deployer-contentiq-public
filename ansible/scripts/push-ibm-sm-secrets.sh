#!/usr/bin/env bash
# Push new versions of ContentIQ backend and RAG secrets to IBM Cloud Secrets Manager.
#
# Uses the same instance URL, secret UUIDs, and payload shapes as:
#   ansible/tekton/task-ibmcloud-secrets-manager-get.yaml
#   ansible/playbooks/deploy.yml (env-stringdata+b64 backend, kubernetes-yaml+b64 RAG)
#
# Prerequisites on this machine: curl, python3 (PyYAML auto-installed in ansible/.push-sm-venv if missing).
# Optional: ibmcloud CLI + secrets-manager plugin (script uses curl by default).
#
# Required:
#   IBM_CLOUD_API_KEY — API key with Secrets Manager write access on the instance
#   Local secret YAML files (see BACKEND_SECRET_FILE / RAG_SECRET_FILE below)
#
# Configuration (env or source ansible/tekton/.env.sm):
#   SECRETS_MANAGER_ENDPOINT_URL
#   BACKEND_SECRET_KEY_ID, RAG_SECRET_KEY_ID
#
# Usage:
#   export IBM_CLOUD_API_KEY='...'
#   source ansible/tekton/.env.sm   # optional: instance URL + secret IDs
#   ./ansible/scripts/push-ibm-sm-secrets.sh
#
#   ./ansible/scripts/push-ibm-sm-secrets.sh --backend-only
#   ./ansible/scripts/push-ibm-sm-secrets.sh --rag-only --dry-run
#   BACKEND_SECRET_FILE=./secrets/backend-secrets.yaml RAG_SECRET_FILE=./secrets/rag-secrets.yaml \
#     ./ansible/scripts/push-ibm-sm-secrets.sh   # override defaults (templates) with filled secrets
#
# After pushing, sync to the cluster (optional):
#   ROLLOUT_RESTART=true ./ansible/playbooks/scripts/sync-ibm-sm-secrets-to-cluster.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${ANSIBLE_ROOT}/.." && pwd)"

END="${SECRETS_MANAGER_ENDPOINT_URL:-https://afa20521-cd75-4864-843f-e59fd0ffd49d.us-south.secrets-manager.appdomain.cloud}"
END="${END%/}"
BACKEND_SECRET_KEY_ID="${BACKEND_SECRET_KEY_ID:-83eec62f-23d7-80d3-de6c-f7aa48c3ec4e}"
RAG_SECRET_KEY_ID="${RAG_SECRET_KEY_ID:-3520bb5f-9050-8928-e812-67ed3c959fa8}"

BACKEND_SECRET_FILE="${BACKEND_SECRET_FILE:-${ANSIBLE_ROOT}/secrets/backend-secrets-template.yaml}"
RAG_SECRET_FILE="${RAG_SECRET_FILE:-${ANSIBLE_ROOT}/secrets/rag-secrets-template.yaml}"
BACKEND_FALLBACK_FILE="${ANSIBLE_ROOT}/secrets/backend-secrets.yaml"
RAG_FALLBACK_FILE="${ANSIBLE_ROOT}/secrets/rag-secrets.yaml"

BACKEND_PAYLOAD_FORMAT="${BACKEND_PAYLOAD_FORMAT:-env-stringdata}"
RAG_PAYLOAD_FORMAT="${RAG_PAYLOAD_FORMAT:-kubernetes-yaml}"
BACKEND_PAYLOAD_BASE64="${BACKEND_PAYLOAD_BASE64:-true}"
RAG_PAYLOAD_BASE64="${RAG_PAYLOAD_BASE64:-true}"
IBM_SM_TLS_VALIDATE="${IBM_SM_TLS_VALIDATE:-true}"

sm_curl() {
  if [[ "${IBM_SM_TLS_VALIDATE}" != "true" ]]; then
    curl -k "$@"
  else
    curl "$@"
  fi
}

PUSH_BACKEND=1
PUSH_RAG=1
DRY_RUN=0
INSTALL_IBMCLOUD_PLUGIN=0

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --backend-only          Update only the backend IBM SM secret
  --rag-only              Update only the RAG IBM SM secret
  --dry-run               Build payloads and print summary; do not POST versions
  --install-ibmcloud-plugin  Run: ibmcloud plugin install secrets-manager (then exit)
  -h, --help              Show this help

Environment:
  IBM_CLOUD_API_KEY       Required unless --dry-run
  IBM_CLOUD_API_KEY_FILE  Read API key from a file (chmod 600 recommended)
  SECRETS_MANAGER_ENDPOINT_URL, BACKEND_SECRET_KEY_ID, RAG_SECRET_KEY_ID
  BACKEND_SECRET_FILE, RAG_SECRET_FILE
  BACKEND_PAYLOAD_FORMAT, RAG_PAYLOAD_FORMAT (see deploy.yml / Tekton sync task)
  BACKEND_PAYLOAD_BASE64, RAG_PAYLOAD_BASE64 (true|false)
  IBM_SM_TLS_VALIDATE     true (default) or false for corporate TLS inspection labs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-only) PUSH_RAG=0 ;;
    --rag-only) PUSH_BACKEND=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --install-ibmcloud-plugin) INSTALL_IBMCLOUD_PLUGIN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ "${END}" != https://* ]]; then
  echo "SECRETS_MANAGER_ENDPOINT_URL must start with https://" >&2
  exit 1
fi

resolve_secret_file() {
  local primary="$1"
  local fallback="$2"
  local label="$3"
  if [[ -f "${primary}" ]]; then
    printf '%s' "${primary}"
    return 0
  fi
  if [[ -f "${fallback}" ]]; then
    echo "warning: ${label} file not found at ${primary}; using template ${fallback}" >&2
    printf '%s' "${fallback}"
    return 0
  fi
  echo "error: no ${label} file at ${primary} or ${fallback}" >&2
  return 1
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
  return 1
}

PYTHON3="${PYTHON3:-python3}"

ensure_pyyaml() {
  if "${PYTHON3}" -c 'import yaml' 2>/dev/null; then
    return 0
  fi
  local venv="${ANSIBLE_ROOT}/.push-sm-venv"
  if [[ ! -x "${venv}/bin/python3" ]]; then
    echo "Creating ${venv} and installing PyYAML…" >&2
    "${PYTHON3}" -m venv "${venv}"
    "${venv}/bin/pip" install -q pyyaml
  fi
  PYTHON3="${venv}/bin/python3"
  export PYTHON3
}

maybe_install_ibmcloud_plugin() {
  if [[ "${INSTALL_IBMCLOUD_PLUGIN}" != "1" ]]; then
    return 0
  fi
  if ! command -v ibmcloud >/dev/null 2>&1; then
    echo "ibmcloud CLI not found. Install from: https://cloud.ibm.com/docs/cli" >&2
    exit 1
  fi
  ibmcloud plugin install secrets-manager -f
  echo "ibmcloud secrets-manager plugin installed."
  exit 0
}

get_access_token() {
  resolve_api_key || {
    echo "Set IBM_CLOUD_API_KEY or IBM_CLOUD_API_KEY_FILE (Secrets Manager write access)." >&2
    exit 1
  }
  local resp
  resp="$(sm_curl -fsS -X POST "https://iam.cloud.ibm.com/identity/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Accept: application/json" \
    --data-urlencode "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
    --data-urlencode "apikey=${IBM_CLOUD_API_KEY}")"
  export IBM_IAM_TOKEN_JSON="$resp"
  "${PYTHON3}" -c 'import json,os; print(json.loads(os.environ["IBM_IAM_TOKEN_JSON"])["access_token"])'
}

build_sm_payload() {
  local k8s_file="$1"
  local fmt="$2"
  local b64_wrap="$3"
  ensure_pyyaml
  "${PYTHON3}" - "$k8s_file" "$fmt" "$b64_wrap" <<'PY'
import base64
import json
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

k8s_path, fmt, b64_wrap = sys.argv[1], sys.argv[2], sys.argv[3].lower() == "true"

with open(k8s_path, encoding="utf-8") as f:
    doc = yaml.safe_load(f)
if not isinstance(doc, dict):
    sys.exit("Kubernetes secret file must be a single YAML document (mapping).")
if doc.get("kind") != "Secret":
    sys.exit("Expected kind: Secret, got %r" % doc.get("kind"))

string_data = doc.get("stringData")
if not isinstance(string_data, dict):
    data = doc.get("data") or {}
    if not isinstance(data, dict):
        sys.exit("Secret must have stringData or data with key/value entries.")
    import base64 as b64mod

    string_data = {}
    for k, v in data.items():
        if v is None:
            string_data[k] = ""
        else:
            string_data[k] = b64mod.b64decode(v).decode("utf-8", errors="replace")


def to_plain(v):
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        return json.dumps(v, separators=(",", ":"))
    return str(v)


def quote_env_value(val: str) -> str:
    if val == "":
        return '""'
    if re.search(r'[\s#"\\]', val) or "=" in val:
        escaped = val.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return val


def k8s_to_env_stringdata(sd: dict) -> str:
    lines = []
    for key in sorted(sd.keys()):
        val = to_plain(sd[key])
        lines.append(f"{key}={quote_env_value(val)}")
    return "\n".join(lines) + "\n"


def k8s_to_kubernetes_yaml(doc: dict) -> str:
    out = {
        "apiVersion": doc.get("apiVersion", "v1"),
        "kind": "Secret",
        "metadata": dict(doc.get("metadata") or {}),
        "type": doc.get("type", "Opaque"),
        "stringData": {k: to_plain(v) for k, v in string_data.items()},
    }
    return yaml.safe_dump(out, sort_keys=False, default_flow_style=False)


raw = ""
if fmt == "env-stringdata":
    raw = k8s_to_env_stringdata(string_data)
elif fmt == "json-stringdata":
    raw = json.dumps({k: to_plain(v) for k, v in string_data.items()}, indent=2) + "\n"
elif fmt == "kubernetes-yaml":
    raw = k8s_to_kubernetes_yaml(doc)
else:
    sys.exit("Unknown format %r (use env-stringdata, json-stringdata, or kubernetes-yaml)" % fmt)

if b64_wrap:
    raw = base64.b64encode(raw.encode("utf-8")).decode("ascii")

sys.stdout.write(raw)
PY
}

create_secret_version() {
  local secret_id="$1"
  local payload_file="$2"
  local token="$3"
  local body_file
  body_file="$(mktemp)"
  "${PYTHON3}" - "$payload_file" >"$body_file" <<'PY'
import json
import sys

payload_path = sys.argv[1]
with open(payload_path, encoding="utf-8") as f:
    payload = f.read()
print(json.dumps({"payload": payload, "custom_metadata": {}}))
PY
  local http_code
  http_code="$(sm_curl -sS -o /tmp/ibmsm-version-response.json -w '%{http_code}' \
    -X POST "${END}/api/v2/secrets/${secret_id}/versions" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data-binary @"${body_file}")"
  rm -f "$body_file"
  if [[ "${http_code}" != "201" && "${http_code}" != "200" ]]; then
    echo "IBM SM secret-version-create failed (HTTP ${http_code}) for secret ${secret_id}" >&2
    if [[ -f /tmp/ibmsm-version-response.json ]]; then
      "${PYTHON3}" -c 'import json,sys; p="/tmp/ibmsm-version-response.json";
try:
  print(json.dumps(json.load(open(p)), indent=2))
except Exception:
  print(open(p).read()[:2000])' 2>/dev/null || cat /tmp/ibmsm-version-response.json >&2
    fi
    return 1
  fi
  "${PYTHON3}" -c 'import json; d=json.load(open("/tmp/ibmsm-version-response.json"));
vid=d.get("id") or (d.get("metadata") or {}).get("id") or d.get("version_id");
print("  new version:", vid or "(see response)")' 2>/dev/null || true
}

summarize_payload() {
  local label="$1"
  local payload_file="$2"
  "${PYTHON3}" - "$label" "$payload_file" <<'PY'
import hashlib
import sys

label, path = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
digest = hashlib.sha256(data).hexdigest()[:12]
print("%s: %d bytes, sha256…%s" % (label, len(data), digest))
PY
}

maybe_install_ibmcloud_plugin
ensure_pyyaml

if [[ "${DRY_RUN}" != "1" ]]; then
  TOKEN="$(get_access_token)"
else
  TOKEN=""
  if ! resolve_api_key; then
    echo "note: --dry-run without IBM_CLOUD_API_KEY (no IAM call)" >&2
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ "${PUSH_BACKEND}" == "1" ]]; then
  BACKEND_FILE="$(resolve_secret_file "${BACKEND_SECRET_FILE}" "${BACKEND_FALLBACK_FILE}" "backend")"
  build_sm_payload "${BACKEND_FILE}" "${BACKEND_PAYLOAD_FORMAT}" "${BACKEND_PAYLOAD_BASE64}" \
    >"${TMP}/backend.payload"
  echo "Backend secret ${BACKEND_SECRET_KEY_ID}:"
  summarize_payload "  payload" "${TMP}/backend.payload"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  (dry-run: not posting)"
  else
    create_secret_version "${BACKEND_SECRET_KEY_ID}" "${TMP}/backend.payload" "${TOKEN}"
    echo "  posted new version."
  fi
fi

if [[ "${PUSH_RAG}" == "1" ]]; then
  RAG_FILE="$(resolve_secret_file "${RAG_SECRET_FILE}" "${RAG_FALLBACK_FILE}" "RAG")"
  build_sm_payload "${RAG_FILE}" "${RAG_PAYLOAD_FORMAT}" "${RAG_PAYLOAD_BASE64}" \
    >"${TMP}/rag.payload"
  echo "RAG secret ${RAG_SECRET_KEY_ID}:"
  summarize_payload "  payload" "${TMP}/rag.payload"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  (dry-run: not posting)"
  else
    create_secret_version "${RAG_SECRET_KEY_ID}" "${TMP}/rag.payload" "${TOKEN}"
    echo "  posted new version."
  fi
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "Dry run complete. Unset --dry-run and set IBM_CLOUD_API_KEY to push."
else
  echo "IBM Secrets Manager push complete."
  echo "To apply on OpenShift: source tekton/.env.sm (if needed), then:"
  echo "  ${ANSIBLE_ROOT}/playbooks/scripts/sync-ibm-sm-secrets-to-cluster.sh"
  echo "Optional rollout: ROLLOUT_RESTART=true ${ANSIBLE_ROOT}/playbooks/scripts/sync-ibm-sm-secrets-to-cluster.sh"
fi
