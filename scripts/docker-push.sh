#!/bin/bash
set -e

# Add timestamp function
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# GitHub Container Registry repository
REPO="ghcr.io/manaflow-ai/cmux"

# Get version from argument or use 'latest'
VERSION=${1:-latest}

log "Starting docker-push.sh with version: ${VERSION}"

# For OrbStack environments, we need to handle Docker push specially
# OrbStack has known issues with docker push hanging when all layers exist
log "Detected environment: $(docker context show 2>/dev/null || echo 'default')"

# Simple approach: build locally, then push with retries
log "Building Docker image locally..."
./scripts/docker-build.sh ${VERSION}

log "Docker build complete, starting push to GHCR..."
log "Repository: ${REPO}"
log "Version: ${VERSION}"

# Check if Docker daemon is responsive
log "Checking Docker daemon..."
if ! docker version >/dev/null 2>&1; then
    log "ERROR: Docker daemon is not responding"
    exit 1
fi

# Check if we're logged in to GHCR
log "Checking GHCR authentication..."
# Try to login to ghcr.io
if ! docker login ghcr.io >/dev/null 2>&1; then
    log "WARNING: May not be authenticated to GHCR properly"
    log "Run: echo \$GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
    log "Attempting push anyway..."
fi

# Function to get local image digest
get_local_digest() {
    local image=$1
    docker inspect --format='{{index .RepoDigests 0}}' ${image} 2>/dev/null | cut -d'@' -f2
}

# Function to get remote image digest
get_remote_digest() {
    local image=$1
    docker manifest inspect ${image} 2>/dev/null | jq -r '.config.digest' 2>/dev/null
}

# Function to push image with smart detection
smart_push() {
    local image=$1
    
    log "Checking if ${image} needs to be pushed..."
    
    # First check if image exists on GHCR
    if docker manifest inspect ${image} >/dev/null 2>&1; then
        log "Image ${image} already exists on GHCR"
        
        # For OrbStack, we can't reliably compare digests, so we'll assume it's up to date
        # if it exists and we just built it
        log "Skipping push as image already exists (recently built)"
        return 0
    fi
    
    log "Image ${image} not found on GHCR, pushing..."
    
    # Try push with timeout
    log "Starting push (this may take a few minutes)..."
    
    # Create a background process for the push
    docker push ${image} &
    local push_pid=$!
    
    # Monitor the push for up to 20 minutes
    local elapsed=0
    local check_interval=5
    local max_wait=1200
    
    while [ $elapsed -lt $max_wait ]; do
        # Check if push is still running
        if ! kill -0 $push_pid 2>/dev/null; then
            # Process finished
            wait $push_pid
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                log "Successfully pushed ${image}"
                return 0
            else
                log "Push failed with exit code $exit_code"
                return 1
            fi
        fi
        
        # Check if image is now accessible on GHCR
        if [ $elapsed -gt 20 ]; then  # Give it 20 seconds before checking
            if docker manifest inspect ${image} >/dev/null 2>&1; then
                log "Image ${image} is now accessible on GHCR"
                # Kill the push process as it's no longer needed
                kill $push_pid 2>/dev/null || true
                wait $push_pid 2>/dev/null || true
                return 0
            fi
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        
        # Show progress
        if [ $((elapsed % 15)) -eq 0 ]; then
            log "Still pushing... ($elapsed seconds elapsed)"
        fi
    done
    
    # Timeout reached
    log "Push timeout after $max_wait seconds"
    kill $push_pid 2>/dev/null || true
    wait $push_pid 2>/dev/null || true
    
    # Final check if it made it
    if docker manifest inspect ${image} >/dev/null 2>&1; then
        log "Image ${image} is accessible on GHCR (pushed successfully)"
        return 0
    else
        log "ERROR: Failed to push ${image}"
        return 1
    fi
}

# Push the versioned image
if ! smart_push ${REPO}:${VERSION}; then
    exit 1
fi

# Also push latest tag
log "Tagging and pushing latest..."
docker tag ${REPO}:${VERSION} ${REPO}:latest

if ! smart_push ${REPO}:latest; then
    log "WARNING: Failed to push latest tag, but versioned tag was pushed successfully"
fi

log "Docker push completed successfully!"
log "Users can now run: docker pull ${REPO}:latest"