#!/usr/bin/env bash
set -euo pipefail
docker build --progress=plain --target test -f Dockerfile -t cmux-env:test .
echo "Tests executed during docker build stage." > /dev/null
