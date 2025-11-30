#!/usr/bin/env bash
set -euo pipefail

# Test script to reproduce and verify the screenshot collector fix
# This script runs inside a Docker container to verify Claude Code is found

echo "=== Testing Screenshot Collector in Docker ==="
echo ""

# Check if ANTHROPIC_API_KEY is set
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ERROR: ANTHROPIC_API_KEY environment variable is not set"
  echo "Please set it in your .env file or export it"
  exit 1
fi

echo "Building test container with Claude Code..."
docker build -t cmux-screenshot-test -f - . <<'DOCKERFILE'
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y curl git && rm -rf /var/lib/apt/lists/*

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash && \
  mv /root/.bun/bin/bun /usr/local/bin/ && \
  ln -s /usr/local/bin/bun /usr/local/bin/bunx

# Install Claude Code globally
RUN bun add -g @anthropic-ai/claude-code@2.0.54

WORKDIR /root/workspace

CMD ["/bin/bash"]
DOCKERFILE

echo ""
echo "=== Verifying Claude Code installation ==="
docker run --rm cmux-screenshot-test bash -c '
echo "1. Checking Claude executable location:"
ls -l /root/.bun/bin/claude

echo ""
echo "2. Checking if executable is valid:"
test -x /root/.bun/bin/claude && echo "   ✓ Executable is valid" || echo "   ✗ Not executable"

echo ""
echo "3. Testing Claude Code version (will fail without API key, but shows it runs):"
/root/.bun/bin/claude --version 2>&1 || echo "   (Expected to fail without auth)"
'

echo ""
echo "=== Testing with Claude Agent SDK ==="
docker run --rm \
  -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
  cmux-screenshot-test bash -c '
# Install the SDK
bun add @anthropic-ai/claude-agent-sdk

# Create a minimal test script
cat > test-sdk.ts <<'\''EOF'\''
import { query } from "@anthropic-ai/claude-agent-sdk";

async function test() {
  console.log("Testing Claude Agent SDK with pathToClaudeCodeExecutable...");

  try {
    for await (const message of query({
      prompt: "Just say hello and exit",
      options: {
        model: "claude-sonnet-4-5",
        pathToClaudeCodeExecutable: "/root/.bun/bin/claude",
        env: {
          CLAUDE_CODE_ENABLE_TELEMETRY: "0",
        },
      },
    })) {
      console.log("Message:", JSON.stringify(message).substring(0, 100));
    }
    console.log("✓ SDK test completed successfully");
  } catch (error) {
    if (error instanceof Error) {
      console.error("✗ SDK test failed:", error.message);
    } else {
      console.error("✗ SDK test failed:", error);
    }
    process.exit(1);
  }
}

test();
EOF

# Run the test
echo "Running SDK test..."
bun run test-sdk.ts
'

echo ""
echo "=== Cleanup ==="
docker rmi cmux-screenshot-test

echo ""
echo "✓ All tests passed!"
