#!/usr/bin/env bash
# Apply backend, RAG, and registry secrets from IBM Secrets Manager (same behavior as
# ansible/tekton/task-contentiq-sync-secrets-from-ibm-sm). Intended for ansible-playbook
# on the install host (localhost + oc + curl + python3).
#
# Required env:
#   SECRETS_MANAGER_ENDPOINT_URL
#   BACKEND_SECRET_KEY_ID, RAG_SECRET_KEY_ID, REGISTRY_SECRET_KEY_ID (set empty to skip that leg)
# Optional:
#   TARGET_NAMESPACE (default contentiq)
#   IBM_CLOUD_API_KEY — else read from oc get secret ibm-secret -n kube-system
#   CONTENTIQ_OC_BINARY — default oc
#   REGISTRY_K8S_SECRET_NAME (default dockerhub-pull)
#   BACKEND_K8S_SECRET_NAME, RAG_K8S_SECRET_NAME
#   BACKEND_PAYLOAD_FORMAT, RAG_PAYLOAD_FORMAT, REGISTRY_PAYLOAD_FORMAT (Tekton param names;
#     backend/RAG: kubernetes-yaml | json-stringdata | env-stringdata)
#   BACKEND_PAYLOAD_BASE64, RAG_PAYLOAD_BASE64, REGISTRY_PAYLOAD_BASE64 — true/false
#   ROLLOUT_RESTART — true to rollout restart backend + RAG
set -euo pipefail

OC_BIN="${CONTENTIQ_OC_BINARY:-${OC_BINARY:-oc}}"
END="${SECRETS_MANAGER_ENDPOINT_URL:-}"
END="${END%/}"
if [[ "${END}" != https://* ]]; then
  echo "SECRETS_MANAGER_ENDPOINT_URL must start with https://" >&2
  exit 1
fi

TARGET_NAMESPACE="${TARGET_NAMESPACE:-contentiq}"
REGISTRY_K8S_SECRET_NAME="${REGISTRY_K8S_SECRET_NAME:-dockerhub-pull}"
BACKEND_K8S_SECRET_NAME="${BACKEND_K8S_SECRET_NAME:-contentiq-backend-secrets}"
RAG_K8S_SECRET_NAME="${RAG_K8S_SECRET_NAME:-personalization-api-secrets}"
BACKEND_PAYLOAD_FORMAT="${BACKEND_PAYLOAD_FORMAT:-env-stringdata}"
RAG_PAYLOAD_FORMAT="${RAG_PAYLOAD_FORMAT:-kubernetes-yaml}"
REGISTRY_PAYLOAD_FORMAT="${REGISTRY_PAYLOAD_FORMAT:-json-stringdata}"
BACKEND_PAYLOAD_BASE64="${BACKEND_PAYLOAD_BASE64:-true}"
RAG_PAYLOAD_BASE64="${RAG_PAYLOAD_BASE64:-true}"
REGISTRY_PAYLOAD_BASE64="${REGISTRY_PAYLOAD_BASE64:-false}"
ROLLOUT_RESTART="${ROLLOUT_RESTART:-false}"

BACKEND_SECRET_KEY_ID="${BACKEND_SECRET_KEY_ID:-}"
RAG_SECRET_KEY_ID="${RAG_SECRET_KEY_ID:-}"
REGISTRY_SECRET_KEY_ID="${REGISTRY_SECRET_KEY_ID:-}"

resolve_api_key() {
  if [[ -n "${IBM_CLOUD_API_KEY:-}" ]]; then
    return 0
  fi
  local apikey_b64 key
  apikey_b64="$("${OC_BIN}" get secret ibm-secret -n kube-system -o jsonpath='{.data.apiKey}' 2>/dev/null)" || {
    echo "Set IBM_CLOUD_API_KEY or ensure kube-system/ibm-secret is readable with ${OC_BIN}." >&2
    return 1
  }
  [[ -n "${apikey_b64}" ]] || return 1
  key="$(printf '%s' "${apikey_b64}" | base64 -d)" || return 1
  [[ -n "${key}" ]] || return 1
  export IBM_CLOUD_API_KEY="${key}"
}

extract_sm_payload() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    j = json.load(f)
data = j.get("data") or {}
p = data.get("payload")
if p is None:
    p = j.get("payload")
if p is None and isinstance(data.get("secret_data"), dict):
    p = data["secret_data"].get("payload")
if p is None:
    sys.stderr.write(
        "Could not find payload in Secrets Manager JSON. Keys at top: %s\n" % list(j.keys())
    )
    sys.exit(1)
if not isinstance(p, str):
    p = json.dumps(p)
sys.stdout.write(p)
PY
}

get_access_token() {
  resolve_api_key || exit 1
  local resp
  resp="$(curl -fsS -X POST "https://iam.cloud.ibm.com/identity/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Accept: application/json" \
    --data-urlencode "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
    --data-urlencode "apikey=${IBM_CLOUD_API_KEY}")"
  export IBM_IAM_TOKEN_JSON="$resp"
  python3 -c 'import json,os; print(json.loads(os.environ["IBM_IAM_TOKEN_JSON"])["access_token"])'
}

fetch_secret_json() {
  local key_id="$1"
  local out="$2"
  local token="$3"
  [[ -n "${key_id}" ]] || return 0
  curl -fsS -X GET "${END}/api/v2/secrets/${key_id}" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    -o "$out"
}

apply_registry_k8s_yaml_payload() {
  local payload_file="$1"
  "${OC_BIN}" apply -f "$payload_file"
}

normalize_registry_k8s_yaml_for_oc_apply() {
  local src="$1"
  local dst="$2"
  python3 - "$src" "$dst" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, encoding="utf-8").read().strip()
if not raw:
    sys.exit("registry SM payload is empty")
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    open(dst, "w", encoding="utf-8").write(raw)
    sys.exit(0)
if isinstance(data, list):
    if not data:
        sys.exit("registry SM JSON is an empty array")
    out = {"apiVersion": "v1", "kind": "List", "items": data}
elif isinstance(data, dict):
    out = data
else:
    sys.exit("registry SM JSON root must be an object or array, not " + type(data).__name__)
with open(dst, "w", encoding="utf-8") as f:
    json.dump(out, f)
PY
}

apply_registry_dockerconfigjson() {
  local payload_file="$1"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$payload_file"
  "${OC_BIN}" create secret docker-registry "${REGISTRY_K8S_SECRET_NAME}" \
    -n "${TARGET_NAMESPACE}" \
    --from-file=.dockerconfigjson="$payload_file" \
    --dry-run=client -o yaml | "${OC_BIN}" apply -f -
}

json_stringdata_to_k8s_secret_file() {
  local payload_file="$1"
  local k8s_secret_name="$2"
  local ns="$3"
  local out_file="$4"
  python3 - "$payload_file" "$k8s_secret_name" "$ns" "$out_file" <<'PY'
import json
import sys

payload_path, name, ns, outp = sys.argv[1:5]
raw = open(payload_path, encoding="utf-8").read().strip()
if not (raw.startswith("{") and raw.endswith("}")):
    raise SystemExit("json-stringdata expects a JSON object in the SM payload")
data = json.loads(raw)
if not isinstance(data, dict):
    raise SystemExit("Root JSON must be an object of string keys")


def to_str(v):
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    return str(v)


string_data = {k: to_str(v) for k, v in data.items()}
manifest = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": name, "namespace": ns},
    "type": "Opaque",
    "stringData": string_data,
}
with open(outp, "w", encoding="utf-8") as f:
    json.dump(manifest, f)
PY
}

env_stringdata_to_k8s_secret_file() {
  local payload_file="$1"
  local k8s_secret_name="$2"
  local ns="$3"
  local out_file="$4"
  python3 - "$payload_file" "$k8s_secret_name" "$ns" "$out_file" <<'PY'
import json
import re
import sys

payload_path, name, ns, outp = sys.argv[1:5]
raw = open(payload_path, encoding="utf-8").read().strip()
if not raw:
    sys.exit("SM payload is empty (env-stringdata)")


def parse_env_stringdata(blob):
    out = {}
    re_colon = re.compile(r"^([A-Za-z_][A-Za-z0-9_.-]*)\s*:\s*(.+)$")
    re_equals = re.compile(r"^([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*(.+)$")
    for raw_line in blob.splitlines():
        s = raw_line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("export "):
            s = s[7:].lstrip()
        m = re_colon.match(s) or re_equals.match(s)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if not key or key.startswith("#"):
            continue
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("\"", "'"):
            val = val[1:-1]
        out[key] = val
    return out


data = parse_env_stringdata(raw)
if not data:
    sys.exit(
        "env-stringdata: no KEY=value or KEY: value entries (comments/blank lines skipped). "
        "If the payload is still base64-wrapped, set BACKEND_PAYLOAD_BASE64 / RAG_PAYLOAD_BASE64 true."
    )
string_data = {k: str(v) for k, v in data.items()}
manifest = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": name, "namespace": ns},
    "type": "Opaque",
    "stringData": string_data,
}
with open(outp, "w", encoding="utf-8") as f:
    json.dump(manifest, f)
PY
}

prepare_sm_payload_file() {
  local sm_json="$1"
  local raw_out="$2"
  local k8s_name="$3"
  local final_out="$4"
  local fmt="$5"
  local decode_b64="${6:-false}"
  [[ -f "${sm_json}" ]] || return 0
  extract_sm_payload "$sm_json" >"$raw_out"
  if [[ "${decode_b64}" == "true" ]]; then
    local tmpf="${raw_out}.b64dec"
    base64 -d <"$raw_out" >"$tmpf" && mv "$tmpf" "$raw_out"
  fi
  case "${fmt}" in
    kubernetes-yaml)
      cp "$raw_out" "$final_out"
      ;;
    json-stringdata)
      json_stringdata_to_k8s_secret_file "$raw_out" "$k8s_name" "${TARGET_NAMESPACE}" "$final_out"
      ;;
    env-stringdata)
      env_stringdata_to_k8s_secret_file "$raw_out" "$k8s_name" "${TARGET_NAMESPACE}" "$final_out"
      ;;
    *)
      echo "Unknown payload format: ${fmt}" >&2
      exit 1
      ;;
  esac
}

TOKEN="$(get_access_token)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "${BACKEND_SECRET_KEY_ID}" ]]; then
  fetch_secret_json "${BACKEND_SECRET_KEY_ID}" "$TMP/backend.json" "$TOKEN"
  prepare_sm_payload_file "$TMP/backend.json" "$TMP/backend.raw" "${BACKEND_K8S_SECRET_NAME}" \
    "$TMP/backend-secret.manifest" "${BACKEND_PAYLOAD_FORMAT}" "${BACKEND_PAYLOAD_BASE64}"
  "${OC_BIN}" apply -f "$TMP/backend-secret.manifest" -n "${TARGET_NAMESPACE}"
fi

if [[ -n "${RAG_SECRET_KEY_ID}" ]]; then
  fetch_secret_json "${RAG_SECRET_KEY_ID}" "$TMP/rag.json" "$TOKEN"
  prepare_sm_payload_file "$TMP/rag.json" "$TMP/rag.raw" "${RAG_K8S_SECRET_NAME}" \
    "$TMP/rag-secret.manifest" "${RAG_PAYLOAD_FORMAT}" "${RAG_PAYLOAD_BASE64}"
  "${OC_BIN}" apply -f "$TMP/rag-secret.manifest" -n "${TARGET_NAMESPACE}"
fi

if [[ -n "${REGISTRY_SECRET_KEY_ID}" ]]; then
  fetch_secret_json "${REGISTRY_SECRET_KEY_ID}" "$TMP/reg.json" "$TOKEN"
  extract_sm_payload "$TMP/reg.json" >"$TMP/registry.payload"
  if [[ "${REGISTRY_PAYLOAD_BASE64}" == "true" ]]; then
    tmpreg="${TMP}/registry.payload.dec"
    base64 -d <"$TMP/registry.payload" >"$tmpreg" && mv "$tmpreg" "$TMP/registry.payload"
  fi
  case "${REGISTRY_PAYLOAD_FORMAT}" in
    kubernetes-yaml)
      normalize_registry_k8s_yaml_for_oc_apply "$TMP/registry.payload" "$TMP/registry.manifest.apply.yaml"
      apply_registry_k8s_yaml_payload "$TMP/registry.manifest.apply.yaml"
      ;;
    json-stringdata)
      json_stringdata_to_k8s_secret_file "$TMP/registry.payload" "${REGISTRY_K8S_SECRET_NAME}" \
        "${TARGET_NAMESPACE}" "$TMP/registry-secret.manifest.json"
      "${OC_BIN}" apply -f "$TMP/registry-secret.manifest.json" -n "${TARGET_NAMESPACE}"
      ;;
    dockerconfigjson)
      apply_registry_dockerconfigjson "$TMP/registry.payload"
      ;;
    *)
      echo "Unknown REGISTRY_PAYLOAD_FORMAT: ${REGISTRY_PAYLOAD_FORMAT}" >&2
      exit 1
      ;;
  esac
fi

if [[ "${ROLLOUT_RESTART}" == "true" ]]; then
  "${OC_BIN}" rollout restart deployment/contentiq-backend -n "${TARGET_NAMESPACE}" || true
  "${OC_BIN}" rollout restart deployment/personalization-rag -n "${TARGET_NAMESPACE}" || true
fi

echo "IBM Secrets Manager sync finished."
