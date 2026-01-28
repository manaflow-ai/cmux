#!/usr/bin/env bash
set -euo pipefail

./scripts/reload.sh &
./scripts/reloadp.sh &
wait
