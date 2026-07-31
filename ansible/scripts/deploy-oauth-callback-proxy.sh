#!/usr/bin/env bash
# Deploy the platform OAuth callback proxy (one-time, not per TechZone reservation).
#
# Register these redirect URIs once with the OAuth providers:
#   https://${ROUTE_HOST}/api/connections/googledrive/auth/google/callback
#   https://${ROUTE_HOST}/api/connections/box/auth/box/callback
#   https://${ROUTE_HOST}/api/connections/microsoft/auth/microsoft/callback
#
# Usage:
#   export KUBECONFIG=...   # platform cluster that owns oauth.contentiq.symplistic.ai DNS
#   ./scripts/deploy-oauth-callback-proxy.sh
#   NS=contentiq-oauth ROUTE_HOST=oauth.contentiq.symplistic.ai ./scripts/deploy-oauth-callback-proxy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-contentiq-oauth}"
OC="${OC:-oc}"
ROUTE_HOST="${ROUTE_HOST:-oauth.contentiq.symplistic.ai}"
OAUTH_CALLBACK_STATE_SECRET="${OAUTH_CALLBACK_STATE_SECRET:?Set OAUTH_CALLBACK_STATE_SECRET to the same value used by ContentIQ backends}"
OAUTH_CALLBACK_ALLOWED_BACKEND_ORIGINS="${OAUTH_CALLBACK_ALLOWED_BACKEND_ORIGINS:-}"
OAUTH_CALLBACK_ALLOWED_BACKEND_SUFFIXES="${OAUTH_CALLBACK_ALLOWED_BACKEND_SUFFIXES:?Set OAUTH_CALLBACK_ALLOWED_BACKEND_SUFFIXES, e.g. techzone.ibm.com,taila4c46d.ts.net}"
MANIFEST_DIR="${ROOT}/manifests/oauth-callback-proxy"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

"${OC}" get namespace "${NS}" >/dev/null 2>&1 || "${OC}" create namespace "${NS}"

echo "Creating ConfigMap from ${MANIFEST_DIR}/proxy.py …"
"${OC}" create configmap contentiq-oauth-callback-proxy \
  --from-file=proxy.py="${MANIFEST_DIR}/proxy.py" \
  -n "${NS}" \
  --dry-run=client -o yaml > "${TMP}/configmap.yaml"
"${OC}" apply -f "${TMP}/configmap.yaml"

echo "Creating callback proxy secret …"
"${OC}" create secret generic contentiq-oauth-callback-proxy-secret \
  --from-literal=OAUTH_CALLBACK_STATE_SECRET="${OAUTH_CALLBACK_STATE_SECRET}" \
  --from-literal=OAUTH_CALLBACK_ALLOWED_BACKEND_ORIGINS="${OAUTH_CALLBACK_ALLOWED_BACKEND_ORIGINS}" \
  --from-literal=OAUTH_CALLBACK_ALLOWED_BACKEND_SUFFIXES="${OAUTH_CALLBACK_ALLOWED_BACKEND_SUFFIXES}" \
  -n "${NS}" \
  --dry-run=client -o yaml > "${TMP}/secret.yaml"
"${OC}" apply -f "${TMP}/secret.yaml"

for f in deployment.yaml service.yaml; do
  echo "Applying ${f} …"
  "${OC}" apply -f "${MANIFEST_DIR}/${f}" -n "${NS}"
done

echo "Restarting callback proxy to load the current script and secret …"
"${OC}" rollout restart deployment/contentiq-oauth-callback-proxy -n "${NS}"
"${OC}" rollout status deployment/contentiq-oauth-callback-proxy -n "${NS}" --timeout=300s

echo "Applying Route (host=${ROUTE_HOST}) …"
sed "s/host: oauth.contentiq.symplistic.ai/host: ${ROUTE_HOST}/" "${MANIFEST_DIR}/route.yaml" \
  | "${OC}" apply -f - -n "${NS}"

echo ""
echo "OK: OAuth callback proxy deployed in namespace ${NS}."
echo "Register in provider consoles:"
echo "  https://${ROUTE_HOST}/api/connections/googledrive/auth/google/callback"
echo "  https://${ROUTE_HOST}/api/connections/box/auth/box/callback"
echo "  https://${ROUTE_HOST}/api/connections/microsoft/auth/microsoft/callback"
echo ""
echo "Set in IBM SM / TechZone deploy vars:"
echo "  contentiq_oauth_fixed_callback_base: https://${ROUTE_HOST}"
echo ""
"${OC}" get route contentiq-oauth-callback-proxy -n "${NS}" -o jsonpath='Router canonical host: {.spec.host}{"\n"}' 2>/dev/null || true
