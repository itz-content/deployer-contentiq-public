#!/usr/bin/env bash
# Register this cluster's OAuth callback URLs in Azure (Microsoft Graph).
# Reads live Routes + platform automation creds from contentiq-backend-secrets.
#
#   export KUBECONFIG=...
#   ./ansible/scripts/sync-oauth-from-cluster.sh
#
# Requires AZURE_GRAPH_CLIENT_ID / AZURE_GRAPH_CLIENT_SECRET in the backend secret
# (separate automation app with Application.ReadWrite.All — not MS_CLIENT_SECRET).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="${CONTENTIQ_OC_BINARY:-${OC_BINARY:-oc}}"
NS="${CONTENTIQ_NAMESPACE:-contentiq}"

read_secret() {
  local key="$1"
  local b64
  b64="$("${OC}" get secret contentiq-backend-secrets -n "${NS}" -o "jsonpath={.data.${key}}" 2>/dev/null || true)"
  if [[ -z "${b64}" ]]; then
    return 1
  fi
  printf '%s' "${b64}" | base64 -d
}

BE="$("${OC}" get route contentiq-backend -n "${NS}" -o jsonpath='{.spec.host}')"
export REDIRECT_URI="https://${BE}/api/connections/microsoft/auth/microsoft/callback"

export TENANT_ID="${AZURE_TENANT_ID:-$(read_secret AZURE_TENANT_ID 2>/dev/null || read_secret MS_EMAIL_TENANT_ID)}"
export TARGET_APP_ID="${TARGET_APP_ID:-$(read_secret MS_CLIENT_ID)}"
export GRAPH_CLIENT_ID="${AZURE_GRAPH_CLIENT_ID:-$(read_secret AZURE_GRAPH_CLIENT_ID)}"
export GRAPH_CLIENT_SECRET="${AZURE_GRAPH_CLIENT_SECRET:-$(read_secret AZURE_GRAPH_CLIENT_SECRET)}"

if [[ -z "${GRAPH_CLIENT_ID}" || -z "${GRAPH_CLIENT_SECRET}" ]]; then
  echo "Missing AZURE_GRAPH_CLIENT_ID / AZURE_GRAPH_CLIENT_SECRET in contentiq-backend-secrets." >&2
  echo "Add a one-time Azure automation app; see DEPLOYMENT-CONFIG.md." >&2
  exit 1
fi

exec bash "${ROOT}/playbooks/scripts/sync-microsoft-oauth-redirect-uri.sh"
