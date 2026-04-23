#!/usr/bin/env bash
# Generate pipelinerun-contentiq-sync-secrets.local.yaml from gitignored .env.sm.
# Use this (or manual copy+edit of the .example file) so nothing sensitive is committed to GitHub.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${DIR}/pipelinerun-contentiq-sync-secrets.local.yaml"
ENV_FILE="${DIR}/.env.sm"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}"
  echo "  cp \"${DIR}/.env.sm.example\" \"${ENV_FILE}\""
  echo "  # edit .env.sm with your endpoint URL and three IBM SM secret UUIDs"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

export SECRETS_MANAGER_ENDPOINT_URL="${SECRETS_MANAGER_ENDPOINT_URL:?set in .env.sm}"
export BACKEND_SECRET_KEY_ID="${BACKEND_SECRET_KEY_ID:?set in .env.sm}"
export RAG_SECRET_KEY_ID="${RAG_SECRET_KEY_ID:?set in .env.sm}"
export REGISTRY_SECRET_KEY_ID="${REGISTRY_SECRET_KEY_ID:?set in .env.sm}"
export TARGET_NAMESPACE="${TARGET_NAMESPACE:-contentiq}"
export REGISTRY_PAYLOAD_FORMAT="${REGISTRY_PAYLOAD_FORMAT:-json-stringdata}"
# Split formats (or legacy BACKEND_RAG_PAYLOAD_FORMAT for both):
if [[ -n "${BACKEND_RAG_PAYLOAD_FORMAT:-}" ]]; then
  export BACKEND_PAYLOAD_FORMAT="${BACKEND_PAYLOAD_FORMAT:-${BACKEND_RAG_PAYLOAD_FORMAT}}"
  export RAG_PAYLOAD_FORMAT="${RAG_PAYLOAD_FORMAT:-${BACKEND_RAG_PAYLOAD_FORMAT}}"
fi
export BACKEND_PAYLOAD_FORMAT="${BACKEND_PAYLOAD_FORMAT:-json-stringdata}"
export RAG_PAYLOAD_FORMAT="${RAG_PAYLOAD_FORMAT:-kubernetes-yaml}"
export BACKEND_PAYLOAD_BASE64="${BACKEND_PAYLOAD_BASE64:-false}"
export RAG_PAYLOAD_BASE64="${RAG_PAYLOAD_BASE64:-true}"
export REGISTRY_PAYLOAD_BASE64="${REGISTRY_PAYLOAD_BASE64:-false}"
export ROLLOUT_RESTART="${ROLLOUT_RESTART:-true}"

python3 - <<'PY' > "${OUT}"
import json
import os

def p(name):
    return {"name": name, "value": os.environ[name]}

pr = {
    "apiVersion": "tekton.dev/v1",
    "kind": "PipelineRun",
    "metadata": {"generateName": "contentiq-sync-secrets-"},
    "spec": {
        "pipelineRef": {"name": "contentiq-sync-secrets-from-ibm-sm"},
        "taskRunTemplate": {"serviceAccountName": "contentiq-sm-sync"},
        "params": [
            p("SECRETS_MANAGER_ENDPOINT_URL"),
            p("BACKEND_SECRET_KEY_ID"),
            p("RAG_SECRET_KEY_ID"),
            p("REGISTRY_SECRET_KEY_ID"),
            p("TARGET_NAMESPACE"),
            p("REGISTRY_PAYLOAD_FORMAT"),
            p("BACKEND_PAYLOAD_FORMAT"),
            p("RAG_PAYLOAD_FORMAT"),
            p("BACKEND_PAYLOAD_BASE64"),
            p("RAG_PAYLOAD_BASE64"),
            p("REGISTRY_PAYLOAD_BASE64"),
            p("ROLLOUT_RESTART"),
        ],
    },
}
print(json.dumps(pr, indent=2))
PY

chmod 600 "${OUT}" 2>/dev/null || true
echo "Wrote ${OUT}"
