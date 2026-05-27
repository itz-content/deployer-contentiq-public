#!/usr/bin/env bash
# Recover contentiq-frontend CrashLoopBackOff (PermissionError on /srv/app/env.json).
# Applies frontend-config keys + strategic deployment patch (initContainer + emptyDir).
#
# Usage: ./scripts/fix-frontend-crashloop.sh
#   NS=contentiq ./scripts/fix-frontend-crashloop.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/align-frontend-env-json.sh"
