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

echo "Aligning contentiq-backend-secrets in ${NS}:"
echo "  FRONTEND_URL=${FRONTEND_URL}"
echo "  CORS_ALLOWED_ORIGINS=${CORS_ALLOWED_ORIGINS}"
echo "  SESSION_COOKIE_DOMAIN=${SESSION_COOKIE_DOMAIN}"

PATCH_JSON="$(python3 - <<PY
import json
print(json.dumps({
    "stringData": {
        "FRONTEND_URL": "${FRONTEND_URL}",
        "CORS_ALLOWED_ORIGINS": "${CORS_ALLOWED_ORIGINS}",
        "SESSION_COOKIE_DOMAIN": "${SESSION_COOKIE_DOMAIN}",
        "MICROSOFT_REDIRECT_URI": "https://${BE}/api/connections/microsoft/auth/microsoft/callback",
        "GOOGLE_REDIRECT_URI": "https://${BE}/api/connections/googledrive/auth/google/callback",
        "BOX_REDIRECT_URI": "https://${BE}/api/connections/box/auth/box/callback",
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
