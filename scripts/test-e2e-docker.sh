#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="cmuxd-e2e"

DOCKER_BUILDKIT=1 docker build -t "$IMAGE_NAME" -f tests/e2e/docker/Dockerfile .

docker run --rm "$IMAGE_NAME"
