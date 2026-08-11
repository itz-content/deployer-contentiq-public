#!/usr/bin/env bash
# Point browser /env.json apiBaseUrl at the live frontend OpenShift Route (same-origin /api)
# so login/WxO session cookies stay first-party via contentiq-frontend-api.
# Set CONTENTIQ_BROWSER_API_SAME_ORIGIN=0 to advertise the backend Route instead (cross-origin).
#
# Usage (after oc login):
#   ./scripts/align-frontend-env-json.sh
#   NS=contentiq ./scripts/align-frontend-env-json.sh
#   CONTENTIQ_BROWSER_API_SAME_ORIGIN=0 ./scripts/align-frontend-env-json.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCH_FILE="${ANSIBLE_DIR}/manifests/frontend-runtime-config-patch.yaml"

NS="${NS:-contentiq}"
OC="${OC:-oc}"
SAME_ORIGIN="${CONTENTIQ_BROWSER_API_SAME_ORIGIN:-1}"

FE="$("${OC}" get route contentiq-frontend -n "${NS}" -o jsonpath='{.spec.host}')"
BE="$("${OC}" get route contentiq-backend -n "${NS}" -o jsonpath='{.spec.host}')"

if [[ -z "${FE}" || -z "${BE}" ]]; then
  echo "FAIL: frontend/backend routes not found in namespace ${NS}"
  exit 1
fi

BACKEND_ORIGIN="https://${BE}"
FRONTEND_ORIGIN="https://${FE}"
if [[ "${SAME_ORIGIN}" == "0" || "${SAME_ORIGIN}" == "false" || "${SAME_ORIGIN}" == "False" ]]; then
  API_BASE="${BACKEND_ORIGIN}"
  MODE="backend Route (cross-origin)"
else
  API_BASE="${FRONTEND_ORIGIN}"
  MODE="frontend origin (same-origin /api)"
fi

echo "Aligning frontend runtime config in ${NS}:"
echo "  CONTENTIQ_API_BASE_URL=${API_BASE}"
echo "  mode: ${MODE}"
echo "  backend origin (tools/CORS): ${BACKEND_ORIGIN}"

if [[ "${API_BASE}" == "${FRONTEND_ORIGIN}" ]]; then
  echo "Ensuring frontend-host /api path Route before same-origin apiBaseUrl..."
  NS="${NS}" OC="${OC}" "${SCRIPT_DIR}/ensure-frontend-api-path-route.sh"
fi

CM_PATCH="$(python3 - <<PY
import json
print(json.dumps({
    "data": {
        "CONTENTIQ_API_BASE_URL": "${API_BASE}",
        "ONPREM_API_URL": "${API_BASE}",
        "CONTENTIQ_PLAYGROUND_STREAM_TIMEOUT_SECONDS": "1800",
    }
}))
PY
)"

"${OC}" patch configmap frontend-config -n "${NS}" --type=merge -p "${CM_PATCH}" 2>/dev/null \
  || echo "WARN: frontend-config not found (operator may create it later)"

if [[ -f "${PATCH_FILE}" ]]; then
  FE_IMAGE="$("${OC}" get deployment contentiq-frontend -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="frontend")].image}' 2>/dev/null || true)"
  PATCH_APPLY="${PATCH_FILE}"
  if [[ -n "${FE_IMAGE}" ]]; then
    PATCH_APPLY="$(mktemp)"
    trap 'rm -f "${PATCH_APPLY}"' EXIT
    sed "s|image: docker.io/symplisticai/contentiq-frontend:.*|image: ${FE_IMAGE}|" \
      "${PATCH_FILE}" > "${PATCH_APPLY}"
  fi
  echo "Applying frontend deployment patch (initContainer renders /srv/app/env.json)..."
  "${OC}" patch deployment contentiq-frontend -n "${NS}" --type=strategic --patch-file "${PATCH_APPLY}"
  if ! "${OC}" get deployment contentiq-frontend -n "${NS}" \
    -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null \
    | grep -q 'render-frontend-env-json'; then
    echo "FAIL: deployment missing initContainer render-frontend-env-json (operator may have reverted the patch)"
    exit 1
  fi
else
  echo "WARN: patch file missing: ${PATCH_FILE}"
fi

echo "Restarting contentiq-frontend..."
"${OC}" rollout restart deployment/contentiq-frontend -n "${NS}"
"${OC}" rollout status deployment/contentiq-frontend -n "${NS}" --timeout=600s

echo ""
echo "Verify /env.json (browser uses this for all API calls):"
ENV_JSON="$(curl -sk "${FRONTEND_ORIGIN}/env.json")"
echo "${ENV_JSON}"
if echo "${ENV_JSON}" | grep -q "\"apiBaseUrl\".*${API_BASE}"; then
  echo "OK: apiBaseUrl matches ${MODE}"
else
  echo "FAIL: apiBaseUrl still wrong — expected ${API_BASE}"
  exit 1
fi

echo ""
echo "Verify backend CORS (for ${FRONTEND_ORIGIN}):"
curl -sk -D - -o /dev/null -H "Origin: ${FRONTEND_ORIGIN}" \
  "${BACKEND_ORIGIN}/api/support/health" | grep -iE 'HTTP/|access-control-allow-origin' || true

echo ""
echo "Done. Hard-refresh the browser (Ctrl+Shift+R). Username/preferences need the API above."
