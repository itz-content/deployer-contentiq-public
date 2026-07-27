#!/usr/bin/env bash
# Fix browser API errors: align backend CORS secrets + frontend /env.json apiBaseUrl to live Routes.
# Also ensures frontend-host /api path Route (Safari empty API_BASE_URL → 404 File not found).
# Run after manual `oc apply -f secrets/backend-secrets-template.yaml` or when the UI calls
# https://backend.contentiq.symplistic.ai instead of your cluster backend route.
#
# Usage (after oc login):
#   ./scripts/fix-app-connectivity.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 1/3 Backend secret (FRONTEND_URL, CORS_ALLOWED_ORIGINS) ==="
"${SCRIPT_DIR}/align-backend-secret-to-routes.sh"

echo ""
echo "=== 2/3 Frontend /env.json (CONTENTIQ_API_BASE_URL → apiBaseUrl) ==="
"${SCRIPT_DIR}/align-frontend-env-json.sh"

echo ""
echo "=== 3/3 Frontend-host /api path Route (Safari same-origin /api) ==="
"${SCRIPT_DIR}/ensure-frontend-api-path-route.sh"
