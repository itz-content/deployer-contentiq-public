#!/usr/bin/env bash
# Apply route timeouts, backend CORS, frontend /env.json, and verify playground config.
# Run where `oc` is logged in (same terminal you use for deploy).
#
# Usage:
#   cd ansible && ./scripts/apply-streaming-and-connectivity-fixes.sh
#   NS=contentiq ./scripts/apply-streaming-and-connectivity-fixes.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NS="${NS:-contentiq}"
OC="${OC:-oc}"
ROUTE_TIMEOUT="${ROUTE_TIMEOUT:-1800s}"
PLAYGROUND_TIMEOUT="${PLAYGROUND_TIMEOUT:-1800}"

echo "=== 0) Cluster context ==="
"${OC}" whoami
"${OC}" project "${NS}" >/dev/null

FE="$("${OC}" get route contentiq-frontend -n "${NS}" -o jsonpath='{.spec.host}')"
BE="$("${OC}" get route contentiq-backend -n "${NS}" -o jsonpath='{.spec.host}')"
if [[ -z "${FE}" || -z "${BE}" ]]; then
  echo "FAIL: contentiq-frontend or contentiq-backend route missing in ${NS}"
  exit 1
fi
FRONTEND_ORIGIN="https://${FE}"
BACKEND_ORIGIN="https://${BE}"

echo ""
echo "Frontend UI URL:  ${FRONTEND_ORIGIN}"
echo "Backend API URL:  ${BACKEND_ORIGIN}"
echo "(Open the UI on the FRONTEND host, not the backend host, to avoid config.js SaaS fallback.)"
echo ""

echo "=== 1) BEFORE: route timeouts ==="
"${OC}" get route -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.haproxy\.router\.openshift\.io/timeout}{"\n"}{end}' || true

echo ""
echo "=== 2) Annotate HAProxy route timeouts (${ROUTE_TIMEOUT}) ==="
for R in contentiq-frontend contentiq-backend; do
  "${OC}" annotate route "${R}" -n "${NS}" --overwrite "haproxy.router.openshift.io/timeout=${ROUTE_TIMEOUT}"
done
echo "Expect: router picks this up within seconds (no pod restart)."

echo ""
echo "=== 3) Backend secret (FRONTEND_URL, CORS) + frontend /env.json ==="
"${SCRIPT_DIR}/fix-app-connectivity.sh"

echo ""
echo "=== 4) Force-render /env.json inside Running frontend pod ==="
POD="$("${OC}" get pods -n "${NS}" -l app=contentiq-frontend --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
echo "Pod: ${POD}"
"${OC}" exec -n "${NS}" "${POD}" -c frontend -- env \
  CONTENTIQ_API_BASE_URL="${BACKEND_ORIGIN}" \
  CONTENTIQ_PLAYGROUND_STREAM_TIMEOUT_SECONDS="${PLAYGROUND_TIMEOUT}" \
  CONTENTIQ_RUNTIME_CONFIG_PATH=/config/env.json \
  python /srv/app/on_prem_packaging/render_runtime_config.py

echo ""
echo "In-pod env.json:"
"${OC}" exec -n "${NS}" "${POD}" -c frontend -- cat /srv/app/env.json || true

echo ""
echo "=== 5) AFTER: public /env.json via frontend route ==="
sleep 3
ENV_JSON="$(curl -sk "${FRONTEND_ORIGIN}/env.json")"
echo "${ENV_JSON}"

if echo "${ENV_JSON}" | grep -q "\"apiBaseUrl\".*${BACKEND_ORIGIN}"; then
  echo "OK: apiBaseUrl"
else
  echo "WARN: apiBaseUrl mismatch — expected ${BACKEND_ORIGIN}"
fi

if echo "${ENV_JSON}" | grep -q 'playgroundStreamTimeoutSeconds'; then
  echo "OK: playgroundStreamTimeoutSeconds present"
else
  echo "WARN: playgroundStreamTimeoutSeconds missing from public /env.json."
  echo "      Your frontend image may not emit this key; route timeout (step 2) still helps."
  echo "      Check playground code for default timeout when key is absent."
fi

echo ""
echo "=== 6) CORS check ==="
curl -sk -D - -o /dev/null -H "Origin: ${FRONTEND_ORIGIN}" \
  "${BACKEND_ORIGIN}/api/support/health" | grep -iE 'HTTP/|access-control-allow-origin' || true

echo ""
echo "=== 7) LAKEHOUSE_INGRESS_PORT from edge-gateway Service (when present) ==="
if "${OC}" get svc edge-gateway -n "${NS}" >/dev/null 2>&1; then
  EG_PORT="$("${OC}" get svc edge-gateway -n "${NS}" -o jsonpath='{.spec.ports[0].port}')"
  CUR_PORT="$("${OC}" get secret contentiq-backend-secrets -n "${NS}" \
    -o jsonpath='{.data.LAKEHOUSE_INGRESS_PORT}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ "${CUR_PORT}" != "${EG_PORT}" ]]; then
    echo "Patching LAKEHOUSE_INGRESS_PORT=${EG_PORT} and restarting backend..."
    "${OC}" patch secret contentiq-backend-secrets -n "${NS}" --type=merge \
      -p "{\"stringData\":{\"LAKEHOUSE_INGRESS_PORT\":\"${EG_PORT}\"}}"
    "${OC}" rollout restart deployment/contentiq-backend -n "${NS}"
    "${OC}" rollout status deployment/contentiq-backend -n "${NS}" --timeout=600s
  else
    echo "OK: LAKEHOUSE_INGRESS_PORT=${CUR_PORT}"
  fi
else
  echo "Skipping lakehouse port patch (edge-gateway Service not found)."
fi

echo ""
echo "=== 8) Re-annotate route timeouts (after backend/frontend rollouts) ==="
for R in contentiq-frontend contentiq-backend; do
  "${OC}" annotate route "${R}" -n "${NS}" --overwrite "haproxy.router.openshift.io/timeout=${ROUTE_TIMEOUT}"
done
"${OC}" get route -n "${NS}" contentiq-frontend contentiq-backend \
  -o custom-columns=NAME:.metadata.name,TIMEOUT:.metadata.annotations.'haproxy\.router\.openshift\.io/timeout'

echo ""
echo "=== Done — when you should see changes ==="
echo "1) Route timeouts (1800s):     Next long SSE/playground request (immediate for new connections)."
echo "2) Frontend rollout:           After step 3 (~1–3 min); then hard-refresh browser (Ctrl+Shift+R)."
echo "3) /env.json in browser:       Immediately after refresh; DevTools → Network → env.json."
echo "4) Playground / ingest UI:     Use ${FRONTEND_ORIGIN} (not ${BACKEND_ORIGIN}) for layout/status/playground."
echo "5) Stop using wrong API host:  No more calls to backend.contentiq.symplistic.ai after refresh on frontend URL."
