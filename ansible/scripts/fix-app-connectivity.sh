#!/usr/bin/env bash
# Fix browser API errors: align backend CORS secrets + frontend /env.json apiBaseUrl to live Routes.
# Also ensures frontend-host /api path Route (Safari empty API_BASE_URL → 404 File not found)
# and backend/frontend HAProxy timeouts (missing → 504 on slow IBM COS list-folder).
# Run after manual `oc apply -f secrets/backend-secrets-template.yaml` or when the UI calls
# https://backend.contentiq.symplistic.ai instead of your cluster backend route.
#
# Usage (after oc login):
#   ./scripts/fix-app-connectivity.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-contentiq}"
OC="${OC:-oc}"
ROUTE_TIMEOUT="${ROUTE_TIMEOUT:-1800s}"

echo "=== 1/4 Backend secret (FRONTEND_URL, CORS_ALLOWED_ORIGINS) ==="
"${SCRIPT_DIR}/align-backend-secret-to-routes.sh"

echo ""
echo "=== 2/4 Frontend /env.json (CONTENTIQ_API_BASE_URL → apiBaseUrl) ==="
"${SCRIPT_DIR}/align-frontend-env-json.sh"

echo ""
echo "=== 3/4 Frontend-host /api path Route (Safari same-origin /api) ==="
"${SCRIPT_DIR}/ensure-frontend-api-path-route.sh"

echo ""
echo "=== 4/4 Route HAProxy timeouts (${ROUTE_TIMEOUT}) ==="
for R in contentiq-frontend contentiq-backend; do
  "${OC}" annotate route "${R}" -n "${NS}" --overwrite \
    "haproxy.router.openshift.io/timeout=${ROUTE_TIMEOUT}"
done
"${OC}" get route -n "${NS}" contentiq-frontend contentiq-backend \
  -o custom-columns=NAME:.metadata.name,TIMEOUT:.metadata.annotations.haproxy\\.router\\.openshift\\.io/timeout
