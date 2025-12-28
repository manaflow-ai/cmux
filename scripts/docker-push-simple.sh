#!/bin/bash
set -e

# Simple Docker push script that works around OrbStack hanging issues
# This script builds and attempts to push, with a timeout to prevent hanging

# Add timestamp function
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# GitHub Container Registry repository
REPO="ghcr.io/manaflow-ai/cmux"

# Get version from argument or use 'latest'
VERSION=${1:-latest}

log "Starting simple docker push for version: ${VERSION}"

# Build the image
log "Building Docker image..."
./scripts/docker-build.sh ${VERSION}

log "Build complete. Attempting push..."

# Function to attempt push with timeout
attempt_push() {
    local tag=$1
    local timeout_seconds=30
    
    log "Attempting to push ${REPO}:${tag}..."
    
    # Start push in background
    docker push ${REPO}:${tag} > /tmp/docker-push-${tag}.log 2>&1 &
    local pid=$!
    
    # Wait for completion or timeout
    local count=0
    while [ $count -lt $timeout_seconds ]; do
        if ! kill -0 $pid 2>/dev/null; then
            # Process finished
            wait $pid
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                log "Successfully pushed ${REPO}:${tag}"
                return 0
            else
                log "Push failed for ${REPO}:${tag}"
                cat /tmp/docker-push-${tag}.log
                return 1
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    
    # Timeout - kill the process
    kill -9 $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    
    # Check if it actually made it to GHCR despite timeout
    if docker manifest inspect ${REPO}:${tag} >/dev/null 2>&1; then
        log "Push appears successful for ${REPO}:${tag} (image is accessible)"
        return 0
    else
        log "Push timed out for ${REPO}:${tag}"
        return 1
    fi
}

# Try to push versioned tag
if attempt_push ${VERSION}; then
    log "Version ${VERSION} pushed successfully"
else
    log "WARNING: Failed to push version ${VERSION}"
    log "This is often due to OrbStack/Docker Desktop issues when all layers already exist"
    log "You may need to manually push later or use a different Docker environment"
fi

# Try to push latest tag
docker tag ${REPO}:${VERSION} ${REPO}:latest
if attempt_push latest; then
    log "Latest tag pushed successfully"
else
    log "WARNING: Failed to push latest tag"
fi

log "Push process complete"
log "To verify: docker manifest inspect ${REPO}:${VERSION}"