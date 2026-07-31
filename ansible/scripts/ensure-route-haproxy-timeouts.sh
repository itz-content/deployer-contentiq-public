#!/usr/bin/env bash
# OpenShift's default router timeout (~30s) is shorter than ContentIQ's slow calls:
# IBM COS list-folder, ingest, export and playground SSE all return 504 without this.
# The operator can strip the annotation when it reconciles Routes, so this re-runs
# after rollouts and fails when a timeout did not stick.
#
# Usage (after oc login):
#   ./scripts/ensure-route-haproxy-timeouts.sh
#   ROUTE_TIMEOUT=600s ./scripts/ensure-route-haproxy-timeouts.sh
set -euo pipefail

NS="${NS:-contentiq}"
OC="${OC:-oc}"
ROUTE_TIMEOUT="${ROUTE_TIMEOUT:-1800s}"
ROUTE_TARGETS="${ROUTE_TARGETS:-contentiq-frontend contentiq-backend}"
# Same-origin /api path Route; only present once ensure-frontend-api-path-route.sh has run.
OPTIONAL_ROUTE_TARGETS="${OPTIONAL_ROUTE_TARGETS:-contentiq-frontend-api}"

targets=()
for R in ${ROUTE_TARGETS}; do
  if ! "${OC}" get route "${R}" -n "${NS}" >/dev/null 2>&1; then
    echo "FAIL: route ${R} not found in ${NS}"
    exit 1
  fi
  targets+=("${R}")
done
for R in ${OPTIONAL_ROUTE_TARGETS}; do
  if "${OC}" get route "${R}" -n "${NS}" >/dev/null 2>&1; then
    targets+=("${R}")
  fi
done

echo "Annotating haproxy.router.openshift.io/timeout=${ROUTE_TIMEOUT} on: ${targets[*]}"
for R in "${targets[@]}"; do
  "${OC}" annotate route "${R}" -n "${NS}" --overwrite \
    "haproxy.router.openshift.io/timeout=${ROUTE_TIMEOUT}"
done

echo ""
echo "Verifying:"
rc=0
for R in "${targets[@]}"; do
  GOT="$("${OC}" get route "${R}" -n "${NS}" \
    -o jsonpath='{.metadata.annotations.haproxy\.router\.openshift\.io/timeout}' 2>/dev/null || true)"
  if [[ "${GOT}" == "${ROUTE_TIMEOUT}" ]]; then
    echo "  OK:   ${R} = ${GOT}"
  else
    echo "  FAIL: ${R} = ${GOT:-<none>} (expected ${ROUTE_TIMEOUT})"
    rc=1
  fi
done

if [[ "${rc}" -ne 0 ]]; then
  echo ""
  echo "A Route did not keep the annotation. The operator may be reconciling it back;"
  echo "re-run after the rollout settles, or check the ContentIQ CR routes spec."
  exit 1
fi

echo ""
echo "Router picks this up within seconds on new connections (no pod restart)."
echo "Note: a TechZone/on-prem load balancer in front of the router can impose its own"
echo "shorter timeout, which this annotation cannot override."
