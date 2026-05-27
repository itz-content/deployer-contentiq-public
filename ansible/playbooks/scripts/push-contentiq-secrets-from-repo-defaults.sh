#!/usr/bin/env bash
# Push backend + RAG from ansible/secrets/*-template.yaml to IBM SM using repo/Tekton defaults.
# Wrapper around ansible/scripts/push-ibm-sm-secrets.sh.
#
#   cd ansible
#   export IBM_CLOUD_API_KEY='...'    # must have SM Writer/Manager on the instance
#   ./playbooks/scripts/push-contentiq-secrets-from-repo-defaults.sh
#   ./playbooks/scripts/push-contentiq-secrets-from-repo-defaults.sh --dry-run
#
# Loads ansible/tekton/.env.sm when present (instance URL + secret UUIDs).
# Does NOT use kube-system/ibm-secret by default (cluster key is often read-only).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUSH_SCRIPT="${ANSIBLE_ROOT}/scripts/push-ibm-sm-secrets.sh"

if [[ -f "${ANSIBLE_ROOT}/tekton/.env.sm" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "${ANSIBLE_ROOT}/tekton/.env.sm"
  set +a
fi

if [[ ! -x "${PUSH_SCRIPT}" ]]; then
  echo "Missing push script: ${PUSH_SCRIPT}" >&2
  exit 1
fi

if [[ -z "${IBM_CLOUD_API_KEY:-}" && -z "${IBM_CLOUD_API_KEY_FILE:-}" && -z "${IBMCLOUD_API_KEY:-}" ]]; then
  echo "Set IBM_CLOUD_API_KEY (Writer/Manager on Secrets Manager). Cluster ibm-secret is often read-only." >&2
  echo "  export IBM_CLOUD_API_KEY='...'" >&2
  echo "  ./playbooks/scripts/check-ibm-sm-apikey-access.sh   # diagnose IAM + SM access" >&2
  exit 1
fi

exec "${PUSH_SCRIPT}" "$@"
