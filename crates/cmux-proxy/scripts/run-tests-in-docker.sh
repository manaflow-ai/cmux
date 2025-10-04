#!/usr/bin/env bash
set -euo pipefail

IMAGE="cmux-proxy-test:latest"

docker build -t "$IMAGE" .

# Run a container (no need to run anything since Dockerfile runs tests), but keep it for logs
echo "Build completed and tests ran in image $IMAGE"

