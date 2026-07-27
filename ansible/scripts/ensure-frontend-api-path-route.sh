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

echo "Waiting for route admit..."
for _ in $(seq 1 30); do
  admitted="$("${OC}" get route "${ROUTE_NAME}" -n "${NS}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
  if [[ "${admitted}" == "True" ]]; then
    break
  fi
  sleep 2
done

echo "Verify same-origin /api on frontend host (expect 401 JSON, not 404 File not found):"
CODE_AND_TYPE="$(curl -sk -o /tmp/ciq-api-path.body -w '%{http_code} %{content_type}' \
  "https://${FE}/api/auth/get-credentials")"
echo "  ${CODE_AND_TYPE}"
head -c 200 /tmp/ciq-api-path.body; echo

if echo "${CODE_AND_TYPE}" | grep -q '^401'; then
  echo "OK: /api is proxied to backend on the frontend host"
else
  BODY="$(cat /tmp/ciq-api-path.body)"
  if echo "${BODY}" | grep -qi 'File not found'; then
    echo "FAIL: still hitting frontend static server (path route not matching)"
    exit 1
  fi
  echo "WARN: unexpected response (not 401). Check route/router if sidebar still shows User."
fi

echo ""
echo "Done. In Safari: open a new Private window → layout.html → log in again."
echo "Network: get-credentials should be 401/200 from the frontend host (proxied), not 404."
