#!/usr/bin/env bash
# Remove ContentIQ install artifacts (same scope as ansible/playbooks/deploy.yml + CUSTOMER-GUIDE).
# Requires: oc login, ansible-playbook, cluster-admin or equivalent for OLM/namespaces.
#
# Usage:
#   ./teardown.sh
#   ./teardown.sh -e contentiq_teardown_delete_pull_secrets=true
#   ./teardown.sh --syntax-check   # passed through to ansible-playbook (use first arg only)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/ansible"

PLAYBOOK_ARGS=(ansible-playbook -i inventory.yml playbooks/teardown.yml)

if [[ -f "${SCRIPT_DIR}/ansible/parameters.yml" ]]; then
  PLAYBOOK_ARGS+=(-e "@${SCRIPT_DIR}/ansible/parameters.yml")
fi

# Safe default: require explicit confirm unless caller passes -e contentiq_teardown_i_understand=true
PLAYBOOK_ARGS+=(-e contentiq_teardown_confirm=true)

if [[ "${1:-}" == "--syntax-check" ]]; then
  exec ansible-playbook --syntax-check playbooks/teardown.yml
fi

exec "${PLAYBOOK_ARGS[@]}" "$@"
