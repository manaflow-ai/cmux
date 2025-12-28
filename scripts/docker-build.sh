#!/bin/bash
set -e

# GitHub Container Registry repository
REPO="ghcr.io/manaflow-ai/cmux"

# Get version from package.json or use 'latest'
VERSION=${1:-latest}

# Build for current platform first (faster for testing)
echo "Building Docker image for current platform..."

# Add a build timestamp label to force a new layer (helps with push issues)
BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
docker build \
    --label "build.version=${VERSION}" \
    --label "build.time=${BUILD_TIME}" \
    -t ${REPO}:${VERSION} \
    -t ${REPO}:latest \
    .

echo "Build complete!"
echo "To push: ./scripts/docker-push.sh ${VERSION}"