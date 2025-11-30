#!/usr/bin/env bash
set -euo pipefail

# Ensure we are in the package root
cd "$(dirname "$0")/.."

# 1. Setup dependencies
echo "Setting up Playwright tests..."
cd tests/playwright
npm install
npx playwright install chromium
cd ../..

# 2. Start Server
echo "Ensuring server is running..."
./scripts/cmux-cli.sh server status

# 3. Setup Sandbox & Target Server
echo "Starting python server in sandbox..."
SANDBOX_ID=$(./scripts/cmux-cli.sh sandboxes create --name proxy-e2e | jq -r .id)
echo "Created sandbox $SANDBOX_ID"

./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- /usr/bin/python3 -m http.server 8000 &
SERVER_PID=$!
sleep 2

# 3b. Start WS Server in sandbox
# Encode script to base64 to avoid escaping hell and shell injection issues
B64_SCRIPT=$(base64 -i scripts/ws_server.py)
# Remove newlines from base64 output if any (Linux base64 wraps by default)
B64_SCRIPT=$(echo "$B64_SCRIPT" | tr -d '\n')

./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- /bin/sh -c "echo '$B64_SCRIPT' | base64 -d > /server.py"

./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- /usr/bin/python3 /server.py &
WS_SERVER_PID=$!


# 4. Start Proxy
PROXY_PORT=9998
echo "Starting proxy on port $PROXY_PORT..."
./scripts/cmux-cli.sh proxy "$SANDBOX_ID" --port "$PROXY_PORT" &
PROXY_PID=$!
sleep 2

# 5. Run Playwright
echo "Running Playwright tests..."
export PROXY_URL="http://127.0.0.1:$PROXY_PORT"
export TARGET_URL="http://localhost:8000"
export WS_TARGET_URL="ws://localhost:8765"

# We run inside the tests/playwright directory
cd tests/playwright
if npx playwright test; then
    echo "Playwright tests PASSED"
    RESULT=0
else
    echo "Playwright tests FAILED"
    RESULT=1
fi
cd ../..

# 6. Cleanup
echo "Cleaning up..."
kill $PROXY_PID || true
kill $SERVER_PID || true
kill $WS_SERVER_PID || true
./scripts/cmux-cli.sh sandboxes delete "$SANDBOX_ID"

exit $RESULT
