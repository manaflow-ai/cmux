#!/bin/bash
set -e

# GitHub Container Registry repository
REPO="ghcr.io/manaflow-ai/cmux"

# Get version from argument or use 'latest'
VERSION=${1:-latest}

echo "Building multi-platform Docker image..."
echo "This will build for linux/amd64 and linux/arm64"

# Use buildx to build and push in one step (more efficient)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag ${REPO}:${VERSION} \
  --tag ${REPO}:latest \
  --push \
  .

echo "Successfully built and pushed multi-platform image to GHCR!"
echo "Users can now run: docker pull ${REPO}:latest"