#!/usr/bin/env bash
# Exercise the same target, storage, scope and rollback gates as production.
set -euo pipefail
cd "$(dirname "$0")/.."
exec bash scripts/deploy-production.sh staging
