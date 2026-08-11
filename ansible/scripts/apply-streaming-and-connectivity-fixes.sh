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
NS="${NS}" OC="${OC}" ROUTE_TIMEOUT="${ROUTE_TIMEOUT}" \
  "${SCRIPT_DIR}/ensure-route-haproxy-timeouts.sh"
echo "Expect: router picks this up within seconds (no pod restart)."

echo ""
echo "=== 3) Backend secret (FRONTEND_URL, CORS) + frontend /env.json ==="
"${SCRIPT_DIR}/fix-app-connectivity.sh"

echo ""
echo "=== 4) Force-render /env.json inside Running frontend pod ==="
POD="$("${OC}" get pods -n "${NS}" -l app=contentiq-frontend --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
echo "Pod: ${POD}"
# Prefer same-origin frontend origin (session cookies); override with CONTENTIQ_BROWSER_API_SAME_ORIGIN=0.
SAME_ORIGIN="${CONTENTIQ_BROWSER_API_SAME_ORIGIN:-1}"
if [[ "${SAME_ORIGIN}" == "0" || "${SAME_ORIGIN}" == "false" || "${SAME_ORIGIN}" == "False" ]]; then
  BROWSER_API_BASE="${BACKEND_ORIGIN}"
else
  BROWSER_API_BASE="${FRONTEND_ORIGIN}"
fi
"${OC}" exec -n "${NS}" "${POD}" -c frontend -- env \
  CONTENTIQ_API_BASE_URL="${BROWSER_API_BASE}" \
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

if echo "${ENV_JSON}" | grep -q "\"apiBaseUrl\".*${BROWSER_API_BASE}"; then
  echo "OK: apiBaseUrl"
else
  echo "WARN: apiBaseUrl mismatch — expected ${BROWSER_API_BASE}"
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
echo "=== 7) Lakehouse backend secret (host, port, token) when edge-gateway present ==="
if "${OC}" get svc edge-gateway -n "${NS}" >/dev/null 2>&1; then
  EG_PORT="$("${OC}" get svc edge-gateway -n "${NS}" -o jsonpath='{.spec.ports[0].port}')"
  CUR_PORT="$("${OC}" get secret contentiq-backend-secrets -n "${NS}" \
    -o jsonpath='{.data.LAKEHOUSE_INGRESS_PORT}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  CUR_HOST="$("${OC}" get secret contentiq-backend-secrets -n "${NS}" \
    -o jsonpath='{.data.LAKEHOUSE_INGRESS_HOST}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  SERVICE_TOKEN="$("${OC}" get secret lakekeeper-auth-tokens -n "${NS}" \
    -o jsonpath='{.data.SERVICE_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  CUR_TOKEN="$("${OC}" get secret contentiq-backend-secrets -n "${NS}" \
    -o jsonpath='{.data.LAKEHOUSE_SERVICE_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  NEED_PATCH=0
  if [[ "${CUR_HOST}" != "edge-gateway" ]]; then NEED_PATCH=1; fi
  if [[ "${CUR_PORT}" != "${EG_PORT}" ]]; then NEED_PATCH=1; fi
  if [[ -n "${SERVICE_TOKEN}" && "${CUR_TOKEN}" != "${SERVICE_TOKEN}" ]]; then NEED_PATCH=1; fi
  if [[ "${NEED_PATCH}" -eq 1 ]]; then
    echo "Patching lakehouse secret (host=${CUR_HOST:-<empty>} port=${CUR_PORT:-<empty>}) and restarting backend..."
    EG_PORT="${EG_PORT}" SERVICE_TOKEN="${SERVICE_TOKEN}" \
      "${OC}" patch secret contentiq-backend-secrets -n "${NS}" --type=merge -p "$(EG_PORT="${EG_PORT}" SERVICE_TOKEN="${SERVICE_TOKEN}" python3 - <<'PY'
import json, os
payload = {"stringData": {"LAKEHOUSE_INGRESS_HOST": "edge-gateway", "LAKEHOUSE_INGRESS_PORT": os.environ["EG_PORT"]}}
tok = os.environ.get("SERVICE_TOKEN", "").strip()
if tok:
    payload["stringData"]["LAKEHOUSE_SERVICE_TOKEN"] = tok
print(json.dumps(payload))
PY
)"
    "${OC}" rollout restart deployment/contentiq-backend -n "${NS}"
    "${OC}" rollout status deployment/contentiq-backend -n "${NS}" --timeout=600s
  else
    echo "OK: LAKEHOUSE_INGRESS_HOST=edge-gateway LAKEHOUSE_INGRESS_PORT=${CUR_PORT} token aligned"
  fi
else
  echo "Skipping lakehouse secret patch (edge-gateway Service not found)."
fi

echo ""
echo "=== 7b) Lakekeeper bootstrap (accept-terms-of-use; idempotent) ==="
if "${OC}" get deployment lakekeeper -n "${NS}" >/dev/null 2>&1 \
  && "${OC}" get deployment contentiq-backend -n "${NS}" >/dev/null 2>&1; then
  BOOT_OUT="$("${OC}" exec -n "${NS}" deploy/contentiq-backend -c backend -- python3 - <<'PY'
import json, os, urllib.error, urllib.request
token = os.environ.get("LAKEHOUSE_SERVICE_TOKEN", "").strip()
headers = {"Content-Type": "application/json", "Accept": "application/json"}
if token:
    headers["Authorization"] = f"Bearer {token}"
with urllib.request.urlopen(urllib.request.Request("http://lakekeeper:8181/management/v1/info", headers=headers), timeout=20) as r:
    info = json.loads(r.read().decode())
if info.get("bootstrapped") is True:
    print("ALREADY_BOOTSTRAPPED")
    raise SystemExit(0)
body = json.dumps({"accept-terms-of-use": True}).encode()
req = urllib.request.Request("http://lakekeeper:8181/management/v1/bootstrap", data=body, headers=headers, method="POST")
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        print(f"BOOTSTRAPPED:{r.getcode()}")
except urllib.error.HTTPError as e:
    if e.code in (204, 409, 422):
        print(f"BOOTSTRAP_OK_CONFLICT:{e.code}")
        raise SystemExit(0)
    print(f"BOOTSTRAP_HTTP_ERROR:{e.code}:{e.read().decode(errors='replace')[:300]}")
    raise SystemExit(1)
PY
)" || true
  echo "${BOOT_OUT}"
  CONFIRM="$("${OC}" exec -n "${NS}" deploy/contentiq-backend -c backend -- python3 - <<'PY'
import json, os, urllib.request
token = os.environ.get("LAKEHOUSE_SERVICE_TOKEN", "").strip()
headers = {"Accept": "application/json"}
if token:
    headers["Authorization"] = f"Bearer {token}"
with urllib.request.urlopen(urllib.request.Request("http://lakekeeper:8181/management/v1/info", headers=headers), timeout=20) as r:
    info = json.loads(r.read().decode())
print(json.dumps({"bootstrapped": bool(info.get("bootstrapped"))}))
raise SystemExit(0 if info.get("bootstrapped") is True else 1)
PY
)" && echo "OK: ${CONFIRM}" || echo "WARN: Lakekeeper still not bootstrapped — structured chat may soft-fail"
else
  echo "Skipping Lakekeeper bootstrap (lakekeeper or contentiq-backend not found)."
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
