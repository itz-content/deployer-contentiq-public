#!/usr/bin/env bash
# Grant admin consent for Application.ReadWrite.All on the OAuth automation app (no Azure Portal UI).
# Run once as a directory admin (Global Admin / Application Administrator / Cloud App Admin).
#
# Prerequisites:
#   az login   # account that can grant admin consent in the tenant
#   Automation app already exists with API permission added in portal OR via this script
#
# Usage:
#   ./ansible/scripts/grant-azure-graph-admin-consent.sh
#   AUTOMATION_APP_ID=d5d64d68-b118-45a0-a270-f5d326897f38 ./ansible/scripts/grant-azure-graph-admin-consent.sh
#
# Optional: load automation app id from azure-graph.env
#   source ansible/scripts/azure-graph.env && ./ansible/scripts/grant-azure-graph-admin-consent.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${AZURE_GRAPH_ENV_FILE:-${SCRIPT_DIR}/azure-graph.env}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${ENV_FILE}"
  set +a
fi

AUTOMATION_APP_ID="${AUTOMATION_APP_ID:-${AZURE_GRAPH_CLIENT_ID:-}}"
if [[ -z "${AUTOMATION_APP_ID}" ]]; then
  echo "Set AUTOMATION_APP_ID or AZURE_GRAPH_CLIENT_ID (automation app, not MS_CLIENT_ID)." >&2
  exit 1
fi

# Microsoft Graph (first-party) + Application.ReadWrite.All application role
GRAPH_RESOURCE_APP_ID="00000003-0000-0000-c000-000000000000"
APP_READWRITE_ALL_ROLE_ID="1bf51dec-5eeb-42c3-a55e-bf833eedad31"

if ! command -v az >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Azure CLI (az) is required for this script.
  brew install azure-cli   # macOS
  az login
  az ad app permission add --id <AUTOMATION_APP_ID> \
    --api 00000003-0000-0000-c000-000000000000 \
    --api-permissions 1bf51dec-5eeb-42c3-a55e-bf833eedad31=Role
  az ad app permission admin-consent --id <AUTOMATION_APP_ID>

Or use PowerShell: Install-Module Microsoft.Graph -Scope CurrentUser
  See DEPLOYMENT-CONFIG.md "Grant Graph admin consent without the portal"
EOF
  exit 1
fi

echo "Signed-in account (must be able to grant admin consent):"
az account show --query "{user:user.name, tenant:tenantId}" -o table 2>/dev/null || {
  echo "Run: az login" >&2
  exit 1
}

echo ""
echo "Automation app (client) id: ${AUTOMATION_APP_ID}"
echo "Adding Application.ReadWrite.All (if not already on the app)…"
az ad app permission add \
  --id "${AUTOMATION_APP_ID}" \
  --api "${GRAPH_RESOURCE_APP_ID}" \
  --api-permissions "${APP_READWRITE_ALL_ROLE_ID}=Role" \
  2>/dev/null || echo "(permission may already exist — continuing)"

echo "Granting admin consent for the tenant…"
az ad app permission admin-consent --id "${AUTOMATION_APP_ID}"

echo ""
echo "Done. Verify in portal (optional): automation app → API permissions → Granted."
echo "Then run: ./ansible/scripts/sync-oauth-from-cluster.sh"
