#!/usr/bin/env bash
# Point browser /env.json apiBaseUrl at the live backend OpenShift Route (not operator defaults
# like https://backend.contentiq.symplistic.ai). Run after deploy or when the UI shows CORS errors
# against the wrong API host.
#
# Usage (after oc login):
#   ./scripts/align-frontend-env-json.sh
#   NS=contentiq ./scripts/align-frontend-env-json.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCH_FILE="${ANSIBLE_DIR}/manifests/frontend-runtime-config-patch.yaml"

NS="${NS:-contentiq}"
OC="${OC:-oc}"

FE="$("${OC}" get route contentiq-frontend -n "${NS}" -o jsonpath='{.spec.host}')"
BE="$("${OC}" get route contentiq-backend -n "${NS}" -o jsonpath='{.spec.host}')"

if [[ -z "${FE}" || -z "${BE}" ]]; then
  echo "FAIL: frontend/backend routes not found in namespace ${NS}"
  exit 1
fi

API_BASE="https://${BE}"
FRONTEND_ORIGIN="https://${FE}"

echo "Aligning frontend runtime config in ${NS}:"
echo "  CONTENTIQ_API_BASE_URL=${API_BASE}"
echo "  (frontend origin ${FRONTEND_ORIGIN})"

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
  echo "OK: apiBaseUrl matches backend route"
else
  echo "FAIL: apiBaseUrl still wrong — expected ${API_BASE}"
  exit 1
fi

echo ""
echo "Verify backend CORS (for ${FRONTEND_ORIGIN}):"
curl -sk -D - -o /dev/null -H "Origin: ${FRONTEND_ORIGIN}" \
  "${API_BASE}/api/support/health" | grep -iE 'HTTP/|access-control-allow-origin' || true

echo ""
echo "Done. Hard-refresh the browser (Ctrl+Shift+R). Username/preferences need the API above."
