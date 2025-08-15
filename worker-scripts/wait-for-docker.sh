#!/bin/sh
set -e

# Wait for Docker daemon to be ready
echo "Waiting for Docker daemon to initialize..."

attempts=0
max_attempts=60  # 30 seconds timeout

while [ $attempts -lt $max_attempts ]; do
    # Check if Docker socket is accessible using curl
    if curl -s --unix-socket /var/run/docker.sock http://localhost/_ping >/dev/null 2>&1; then
        echo "Docker daemon is ready!"
        exit 0
    fi
    
    attempts=$((attempts + 1))
    
    # Progress indicator every 5 seconds
    if [ $((attempts % 10)) -eq 0 ]; then
        echo "Still waiting... ($((attempts / 2))s elapsed)"
    fi
    
    sleep 0.05
done

echo "Docker daemon failed to start within 30 seconds"
exit 1

