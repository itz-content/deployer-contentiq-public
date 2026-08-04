#!/usr/bin/env bash
# Safari (and any client with empty API_BASE_URL) calls same-origin /api/* on the
# frontend host. Without this route those hit Python SimpleHTTP → 404 "File not found"
# and the sidebar stays on "User". Chrome often still works via /env.json → backend host.
#
# Creates path-based Route: https://<frontend>/api/* → contentiq-backend Service.
# Safe for Chrome: absolute apiBaseUrl traffic still uses the backend Route.
#
# Usage (after oc login):
#   ./scripts/ensure-frontend-api-path-route.sh
set -euo pipefail

NS="${NS:-contentiq}"
OC="${OC:-oc}"
ROUTE_NAME="${ROUTE_NAME:-contentiq-frontend-api}"

FE="$("${OC}" get route contentiq-frontend -n "${NS}" -o jsonpath='{.spec.host}')"
if [[ -z "${FE}" ]]; then
  echo "FAIL: contentiq-frontend route not found in ${NS}"
  exit 1
fi

echo "Ensuring path route ${ROUTE_NAME} on host ${FE} path=/api → contentiq-backend"

"${OC}" apply -n "${NS}" -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${ROUTE_NAME}
  namespace: ${NS}
  annotations:
    haproxy.router.openshift.io/timeout: "1800s"
    # Prefer this path match over the catch-all frontend Route.
    haproxy.router.openshift.io/balance: source
spec:
  host: ${FE}
  path: /api
  to:
    kind: Service
    name: contentiq-backend
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF

# Admit is not enough: HAProxy may still serve the catch-all frontend Route for a short
# window after the path Route is Admitted. Retry the live probe until /api hits backend.
PROBE_URL="https://${FE}/api/auth/get-credentials"
PROBE_RETRIES="${PROBE_RETRIES:-45}"
PROBE_DELAY_SECONDS="${PROBE_DELAY_SECONDS:-2}"
PROBE_BODY="${TMPDIR:-/tmp}/ciq-api-path.$$.body"
trap 'rm -f "${PROBE_BODY}"' EXIT

echo "Waiting for path route to serve backend (expect 401 JSON; Admit alone is not enough)..."
ok=0
last_code_and_type=""
for attempt in $(seq 1 "${PROBE_RETRIES}"); do
  admitted="$("${OC}" get route "${ROUTE_NAME}" -n "${NS}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
  last_code_and_type="$(curl -sk -o "${PROBE_BODY}" -w '%{http_code} %{content_type}' "${PROBE_URL}" || true)"
  if echo "${last_code_and_type}" | grep -q '^401'; then
    echo "  attempt ${attempt}/${PROBE_RETRIES}: ${last_code_and_type} (Admitted=${admitted:-unknown})"
    ok=1
    break
  fi
  body_snip="$(head -c 120 "${PROBE_BODY}" 2>/dev/null | tr '\n' ' ' || true)"
  echo "  attempt ${attempt}/${PROBE_RETRIES}: ${last_code_and_type} (Admitted=${admitted:-unknown}) — ${body_snip}"
  sleep "${PROBE_DELAY_SECONDS}"
done

echo "Verify same-origin /api on frontend host:"
echo "  ${last_code_and_type}"
head -c 200 "${PROBE_BODY}" 2>/dev/null; echo

if [[ "${ok}" -eq 1 ]]; then
  echo "OK: /api is proxied to backend on the frontend host"
else
  BODY="$(cat "${PROBE_BODY}" 2>/dev/null || true)"
  if echo "${BODY}" | grep -qiE 'File not found|Error response'; then
    echo "FAIL: still hitting frontend static server after ${PROBE_RETRIES} probes (~$((PROBE_RETRIES * PROBE_DELAY_SECONDS))s)."
    echo "Check: oc get route ${ROUTE_NAME} contentiq-frontend -n ${NS} -o wide"
    exit 1
  fi
  echo "FAIL: unexpected response after ${PROBE_RETRIES} probes (expected 401 JSON)."
  exit 1
fi

echo ""
echo "Done. In Safari: open a new Private window → layout.html → log in again."
echo "Network: get-credentials should be 401/200 from the frontend host (proxied), not 404."
