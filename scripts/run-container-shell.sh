#!/bin/bash

# Build the Docker image
echo "Building Docker image..."
docker build -t cmux-shell .

# Run the container with a modified entrypoint that starts services but keeps shell
echo "Starting container with shell..."
docker run -it \
  --rm \
  --privileged \
  -p 39376:39376 \
  -p 39377:39377 \
  -p 39378:39378 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v docker-data:/var/lib/docker \
  --name cmux-shell \
  --entrypoint bash \
  cmux-shell \
  -c '
    # Run the startup script but modify the last line to run the worker in background
    # and keep the shell

    # Copy and run all of startup.sh except the last exec line
    sed "s/^exec node/node/" /startup.sh > /tmp/startup-shell.sh
    chmod +x /tmp/startup-shell.sh

    # Run the modified startup script in background
    /tmp/startup-shell.sh &

    # Give it a moment to start
    sleep 2

    # Print status
    echo ""
    echo "========================================="
    echo "Container services started:"
    echo "  - Worker: http://localhost:39377"
    echo "  - VS Code: http://localhost:39378"
    echo "========================================="
    echo ""

    # Start an interactive shell
    exec bash
  '