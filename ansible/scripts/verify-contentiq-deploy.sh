#!/usr/bin/env bash
# Quick health checks for a ContentIQ OpenShift deploy (run after oc login).
# Usage:
#   ./scripts/verify-contentiq-deploy.sh
#   NS=contentiq ./scripts/verify-contentiq-deploy.sh
set -euo pipefail

NS="${NS:-contentiq}"
OC="${OC:-oc}"

echo "=== ContentIQ deploy verification (namespace: ${NS}) ==="
echo ""

FE="$("${OC}" get route contentiq-frontend -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
BE="$("${OC}" get route contentiq-backend -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"

if [[ -z "${FE}" || -z "${BE}" ]]; then
  echo "FAIL: Could not read frontend/backend route hostnames. Is the CR reconciled?"
  "${OC}" get routes -n "${NS}" 2>/dev/null || true
  exit 1
fi

echo "Frontend route: https://${FE}"
echo "Backend route:  https://${BE}"
echo ""

echo "--- 1) /env.json (browser runtime config) ---"
ENV_JSON="$(curl -sk "https://${FE}/env.json")"
echo "${ENV_JSON}"
if echo "${ENV_JSON}" | grep -q "\"apiBaseUrl\".*https://${BE}"; then
  echo "OK: apiBaseUrl matches backend route"
else
  echo "WARN: apiBaseUrl missing or does not match backend route"
fi
echo ""

echo "--- 2) frontend-config ConfigMap ---"
"${OC}" get configmap frontend-config -n "${NS}" -o yaml 2>/dev/null | grep -E '^(  )?(ONPREM_API_URL|CONTENTIQ_API_BASE_URL|PORT):' || echo "WARN: frontend-config not found"
echo ""

echo "--- 3) Backend health + CORS ---"
curl -sk -H "Origin: https://${FE}" -D - -o /tmp/ciq-health.json "https://${BE}/api/support/health" 2>&1 | grep -iE 'HTTP/|access-control-allow-origin' || true
cat /tmp/ciq-health.json
echo ""
echo ""

echo "--- 4) Backend secret URL keys (decoded) ---"
for KEY in FRONTEND_URL CORS_ALLOWED_ORIGINS; do
  VAL="$("${OC}" get secret contentiq-backend-secrets -n "${NS}" -o "jsonpath={.data.${KEY}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
  echo "${KEY}=${VAL}"
  if [[ "${VAL}" != "https://${FE}" ]]; then
    echo "  WARN: expected https://${FE}"
  fi
done
echo ""

echo "--- 5) Route HAProxy timeouts ---"
"${OC}" get route -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.haproxy\.router\.openshift\.io/timeout}{"\n"}{end}' 2>/dev/null || true
echo ""

echo "--- 6) Core pod status ---"
"${OC}" get pods -n "${NS}" -o wide 2>/dev/null | grep -E 'NAME|contentiq-|edge-|personalization|postgres|lakekeeper|trino' || "${OC}" get pods -n "${NS}"
echo ""

echo "--- 7) LAKEHOUSE keys in contentiq-backend-secrets (operator injects here, not deployment env --list) ---"
for KEY in LAKEHOUSE_ENABLED LAKEHOUSE_INGRESS_HOST LAKEHOUSE_SERVICE_TOKEN TRINO_URL; do
  VAL="$("${OC}" get secret contentiq-backend-secrets -n "${NS}" -o "jsonpath={.data.${KEY}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -n "${VAL}" ]]; then
    if [[ "${KEY}" == *TOKEN* ]]; then
      echo "${KEY}=***set***"
    else
      echo "${KEY}=${VAL}"
    fi
  else
    echo "${KEY}=(missing)"
  fi
done
echo ""

echo "--- 8) edge-gateway Service ports/endpoints ---"
"${OC}" get svc edge-gateway -n "${NS}" -o wide 2>/dev/null || echo "WARN: Service edge-gateway not found"
"${OC}" get endpointslices -n "${NS}" -l kubernetes.io/service-name=edge-gateway 2>/dev/null \
  | head -5 || "${OC}" get endpoints edge-gateway -n "${NS}" 2>/dev/null | head -5 || true
echo ""

echo "--- 9) edge-gateway from backend (needs Host: lakekeeper.local + Bearer; try :8080 and :80) ---"
BACKEND_CONTAINER="$("${OC}" get deployment contentiq-backend -n "${NS}" \
  -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || echo backend)"
BACKEND_POD="$("${OC}" get pods -n "${NS}" -l app=contentiq-backend \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${BACKEND_POD}" ]]; then
  "${OC}" exec -n "${NS}" "${BACKEND_POD}" -c "${BACKEND_CONTAINER}" -- python3 <<'PY'
import os, urllib.request
token = os.environ.get("LAKEHOUSE_SERVICE_TOKEN", "")
host_hdr = "lakekeeper.local"
for port in ("8080", "80"):
    url = f"http://edge-gateway:{port}/management/v1/warehouse"
    req = urllib.request.Request(url, headers={
        "Host": host_hdr,
        "Authorization": f"Bearer {token}",
    })
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            print(f"OK: {url} Host={host_hdr} HTTP {r.status}")
            break
    except Exception as e:
        print(f"FAIL: {url} -> {e}")
else:
    print("Hint: if only :8080 works, patch secret LAKEHOUSE_INGRESS_PORT=8080 and restart backend")
PY
else
  echo "WARN: no Running backend pod found"
fi
echo ""

echo "--- 10) LAKEHOUSE_* inside Running backend pod (from secret envFrom) ---"
if [[ -n "${BACKEND_POD}" ]]; then
  "${OC}" exec -n "${NS}" "${BACKEND_POD}" -c "${BACKEND_CONTAINER}" -- env 2>/dev/null \
    | grep -E '^LAKEHOUSE_|^TRINO_URL=' || echo "(no LAKEHOUSE_/TRINO_URL in pod env — check secret + rollout restart)"
else
  echo "SKIP: no Running backend pod"
fi
echo ""

echo "Done. In browser DevTools, also run:"
echo "  fetch('/env.json',{cache:'no-store'}).then(r=>r.json()).then(console.log)"
echo "  console.log(window.API_BASE_URL)"
echo "Expected apiBaseUrl / API_BASE_URL: https://${BE}"
