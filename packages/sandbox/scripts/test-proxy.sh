#!/usr/bin/env bash
set -euo pipefail

# Ensure server is running
./scripts/cmux-cli.sh server status

# Start a simple python server in sandbox 0
echo "Starting python server in sandbox..."
# Create a sandbox and capture ID
SANDBOX_ID=$(./scripts/cmux-cli.sh sandboxes create --name proxy-test | jq -r .id)
echo "Created sandbox $SANDBOX_ID"

# Start python server in background using 'sandboxes exec'
./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- /usr/bin/python3 -m http.server 8000 &
SERVER_PID=$!
echo "Python server started with PID $SERVER_PID"

# Give python a moment to start
sleep 2

echo "Starting proxy on port 9999..."
./scripts/cmux-cli.sh proxy "$SANDBOX_ID" --port 9999 &
PROXY_PID=$!
echo "Proxy started with PID $PROXY_PID"

# Give proxy a moment to start
sleep 2

echo "Testing Proxy..."
curl -v -x http://127.0.0.1:9999 http://localhost:8000/

echo "Cleaning up..."
kill $PROXY_PID || true
kill $SERVER_PID || true
./scripts/cmux-cli.sh sandboxes delete "$SANDBOX_ID"