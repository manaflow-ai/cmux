#!/usr/bin/env bash
set -euo pipefail

# Ensure we are in the package root
cd "$(dirname "$0")/.."

# 1. Setup Playwright dependencies (if not already)
echo "Setting up Playwright..."
cd tests/playwright
npm install
npx playwright install chromium
cd ../..

# 2. Ensure Server is running with latest image
echo "Restarting server to use latest image..."
./scripts/cmux-cli.sh server restart

# 3. Setup Sandbox & Vite App
echo "Checking host npm..."
which npm
ls -l $(which npm)

echo "Creating sandbox for Vite..."
SANDBOX_ID=$(./scripts/cmux-cli.sh sandboxes create --name vite-test | jq -r .id)
echo "Created sandbox $SANDBOX_ID"

echo "Checking sandbox npm..."
./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- ls -l /usr/bin/npm || true
./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- env

echo "Installing dependencies and scaffolding Vite app in sandbox..."
# We use 'npm create vite' non-interactively.
# Using /workspace/app
./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- mkdir /workspace/app

# Init app
./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- \
  /bin/sh -c "cd /workspace/app && npm create vite@latest . -- --template react"

# Install deps
./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- \
  /bin/sh -c "cd /workspace/app && npm install"

# Debug: Check app structure
./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- ls -R /workspace/app
./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- cat /workspace/app/index.html

# Start Vite server
# --host is required to listen on 0.0.0.0 so we can reach it from the network namespace
echo "Starting Vite server..."
./scripts/cmux-cli.sh sandboxes exec "$SANDBOX_ID" -- \
  /bin/sh -c "cd /workspace/app && npm run dev -- --host 0.0.0.0 --port 5173" &
VITE_PID=$!
# Wait for Vite to be ready
echo "Waiting for Vite to start..."
sleep 5

# 4. Start Proxy
PROXY_PORT=9997
echo "Starting proxy on port $PROXY_PORT..."
./scripts/cmux-cli.sh proxy "$SANDBOX_ID" --port "$PROXY_PORT" & 
PROXY_PID=$!
sleep 2

# 5. Run Playwright Tests
echo "Running Playwright Vite tests..."
export PROXY_URL="http://127.0.0.1:$PROXY_PORT"

# We filter to run only vite.spec.ts
cd tests/playwright
if npx playwright test tests/vite.spec.ts; then
    echo "Vite tests PASSED"
    RESULT=0
else
    echo "Vite tests FAILED"
    RESULT=1
fi
cd ../..

# 6. Cleanup
echo "Cleaning up..."
kill $PROXY_PID || true
kill $VITE_PID || true
./scripts/cmux-cli.sh sandboxes delete "$SANDBOX_ID"

exit $RESULT
