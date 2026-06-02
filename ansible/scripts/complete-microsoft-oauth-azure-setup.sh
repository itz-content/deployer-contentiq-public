#!/usr/bin/env bash
# End-to-end: push AZURE_GRAPH_* to IBM SM, sync cluster, register redirect URI on MS_CLIENT_ID app.
#
# Prerequisite: Azure automation app created (Application.ReadWrite.All, admin consent).
#
#   cp scripts/azure-graph.env.example scripts/azure-graph.env   # fill in, chmod 600
#   export KUBECONFIG=...
#   ./scripts/complete-microsoft-oauth-azure-setup.sh
#
# Or pass env vars directly (do not commit secrets):
#   export AZURE_GRAPH_CLIENT_ID='...' AZURE_GRAPH_CLIENT_SECRET='...'
#   export KUBECONFIG=... IBM_CLOUD_API_KEY='...'   # optional if cluster ibm-secret works
#   ./scripts/complete-microsoft-oauth-azure-setup.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${AZURE_GRAPH_ENV_FILE:-${ROOT}/scripts/azure-graph.env}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${ENV_FILE}"
  set +a
fi

: "${AZURE_GRAPH_CLIENT_ID:?Set AZURE_GRAPH_CLIENT_ID (automation app, not MS_CLIENT_ID or MS_EMAIL_CLIENT_ID)}"
: "${AZURE_GRAPH_CLIENT_SECRET:?Set AZURE_GRAPH_CLIENT_SECRET}"

export AZURE_GRAPH_CLIENT_ID AZURE_GRAPH_CLIENT_SECRET
export AZURE_TENANT_ID="${AZURE_TENANT_ID:-a8ac9046-c246-41ea-98e8-448847f3dbf2}"

echo "=== 1/3 Push AZURE_GRAPH_* to IBM Secrets Manager ==="
# SM push always; cluster sync uses env-stringdata (see add-azure-graph-keys --sync-cluster).
if [[ "${SKIP_IBM_SM_PUSH:-false}" == "true" ]]; then
  echo "(SKIP_IBM_SM_PUSH=true — re-syncing cluster from existing SM version only)"
  set -a
  [[ -f "${ROOT}/tekton/.env.sm" ]] && source "${ROOT}/tekton/.env.sm"
  set +a
  ROLLOUT_RESTART=true \
    BACKEND_PAYLOAD_FORMAT=env-stringdata \
    BACKEND_PAYLOAD_BASE64=true \
    RAG_SECRET_KEY_ID="" \
    REGISTRY_SECRET_KEY_ID="" \
    "${ROOT}/playbooks/scripts/sync-ibm-sm-secrets-to-cluster.sh"
else
  "${ROOT}/playbooks/scripts/add-azure-graph-keys-to-ibm-sm-backend.sh" --sync-cluster
fi

echo ""
echo "=== 2/3 Verify keys on cluster ==="
OC="${CONTENTIQ_OC_BINARY:-${OC_BINARY:-oc}}"
NS="${CONTENTIQ_NAMESPACE:-contentiq}"
for k in AZURE_GRAPH_CLIENT_ID AZURE_GRAPH_CLIENT_SECRET AZURE_TENANT_ID; do
  if "${OC}" get secret contentiq-backend-secrets -n "${NS}" -o "jsonpath={.data.${k}}" 2>/dev/null | grep -q .; then
    echo "  ${k}: ok"
  else
    echo "  ${k}: MISSING after SM sync — check sync-ibm-sm-secrets-to-cluster.sh" >&2
    exit 1
  fi
done

echo ""
echo "=== 3/3 Register Microsoft redirect URI via Graph ==="
"${ROOT}/scripts/sync-oauth-from-cluster.sh"

echo ""
echo "Done. Retry Connect Microsoft / SharePoint in the UI."
