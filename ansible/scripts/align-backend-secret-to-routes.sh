#!/usr/bin/env bash
# Restore FRONTEND_URL / CORS_ALLOWED_ORIGINS (and related keys) from live OpenShift Routes.
# Run this after a manual `oc apply -f secrets/backend-secrets-template.yaml` that left
# __CONTENTIQ_*__ placeholders, or whenever login fails with a browser CORS error.
#
# Usage (after oc login):
#   ./scripts/align-backend-secret-to-routes.sh
#   NS=contentiq ./scripts/align-backend-secret-to-routes.sh
set -euo pipefail

NS="${NS:-contentiq}"
OC="${OC:-oc}"
# Set to an empty string only when Google/Box callbacks are registered directly
# against each reservation backend instead of the fixed platform proxy.
OAUTH_CALLBACK_PROXY_BASE="${OAUTH_CALLBACK_PROXY_BASE-https://oauth.contentiq.symplistic.ai}"
OAUTH_CALLBACK_PROXY_BASE="${OAUTH_CALLBACK_PROXY_BASE%/}"

FE="$("${OC}" get route contentiq-frontend -n "${NS}" -o jsonpath='{.spec.host}')"
BE="$("${OC}" get route contentiq-backend -n "${NS}" -o jsonpath='{.spec.host}')"

if [[ -z "${FE}" || -z "${BE}" ]]; then
  echo "FAIL: frontend/backend routes not found in namespace ${NS}"
  exit 1
fi

# Match deploy.yml Step 6b: strip first hostname label for cookie domain.
SESSION_COOKIE_DOMAIN="${FE#*.}"
SESSION_COOKIE_DOMAIN=".${SESSION_COOKIE_DOMAIN}"

FRONTEND_URL="https://${FE}"
CORS_ALLOWED_ORIGINS="${FRONTEND_URL}"
# WXO ContentIQ tools bake this URL at upload time. Without it, INGESTION_SERVER=prod
# defaults tools to https://backend.contentiq.symplistic.ai and on-prem chat never hits RAG.
CONTENTIQ_TOOL_API_ENDPOINT="https://${BE}/api/external/contentiq-tool-query"
OAUTH_REDIRECT_BASE="${OAUTH_CALLBACK_PROXY_BASE:-https://${BE}}"

echo "Aligning contentiq-backend-secrets in ${NS}:"
echo "  FRONTEND_URL=${FRONTEND_URL}"
echo "  CORS_ALLOWED_ORIGINS=${CORS_ALLOWED_ORIGINS}"
echo "  SESSION_COOKIE_DOMAIN=${SESSION_COOKIE_DOMAIN}"
echo "  OAUTH_CALLBACK_PROXY_BASE=${OAUTH_CALLBACK_PROXY_BASE:-<direct backend callbacks>}"
echo "  OAUTH_CALLBACK_BACKEND_ORIGIN=https://${BE}"
echo "  CONTENTIQ_TOOL_API_ENDPOINT=${CONTENTIQ_TOOL_API_ENDPOINT}"

PATCH_JSON="$(python3 - <<PY
import json
print(json.dumps({
    "stringData": {
        "FRONTEND_URL": "${FRONTEND_URL}",
        "CORS_ALLOWED_ORIGINS": "${CORS_ALLOWED_ORIGINS}",
        "SESSION_COOKIE_DOMAIN": "${SESSION_COOKIE_DOMAIN}",
        "SESSION_COOKIE_SAMESITE": "None",
        "SESSION_COOKIE_SECURE": "true",
        "MICROSOFT_REDIRECT_URI": "https://${BE}/api/connections/microsoft/auth/microsoft/callback",
        "GOOGLE_REDIRECT_URI": "${OAUTH_REDIRECT_BASE}/api/connections/googledrive/auth/google/callback",
        "BOX_REDIRECT_URI": "${OAUTH_REDIRECT_BASE}/api/connections/box/auth/box/callback",
        "OAUTH_CALLBACK_PROXY_BASE": "${OAUTH_CALLBACK_PROXY_BASE}",
        "OAUTH_CALLBACK_BACKEND_ORIGIN": "https://${BE}",
        # OpenShift random UID cannot write under /app; avoid playground 500s on timestamp POST.
        "THREAD_MESSAGE_TIMESTAMPS_FILE": "/tmp/.thread_message_timestamps.json",
        "CONTENTIQ_TOOL_API_ENDPOINT": "${CONTENTIQ_TOOL_API_ENDPOINT}",
    }
}))
PY
)"

"${OC}" patch secret contentiq-backend-secrets -n "${NS}" --type=merge -p "${PATCH_JSON}"

echo "Restarting contentiq-backend..."
"${OC}" rollout restart deployment/contentiq-backend -n "${NS}"
"${OC}" rollout status deployment/contentiq-backend -n "${NS}" --timeout=600s

echo ""
echo "Verify CORS:"
curl -sk -D - -o /dev/null -H "Origin: ${FRONTEND_URL}" "https://${BE}/api/support/health" \
  | grep -iE 'HTTP/|access-control-allow-origin' || true
echo ""
echo "Done. Next run ./scripts/align-frontend-env-json.sh (or ./scripts/fix-app-connectivity.sh) so /env.json apiBaseUrl matches this backend."
