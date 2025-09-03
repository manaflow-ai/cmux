import type {
  EnvironmentContext,
  EnvironmentResult,
} from "../common/environment-result.js";

export async function getAugmentEnvironment(
  _ctx: EnvironmentContext
): Promise<EnvironmentResult> {
  // These must be lazy since configs are imported into the browser
  const { readFile } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { Buffer } = await import("node:buffer");

  const files: EnvironmentResult["files"] = [];
  const env: Record<string, string> = {};
  const startupCommands: string[] = [];

  // Ensure directories exist
  startupCommands.unshift("mkdir -p ~/.augment");
  startupCommands.push("mkdir -p /root/lifecycle/augment");
  g;
  // Clean up any previous Augment completion markers
  startupCommands.push(
    "rm -f /root/lifecycle/augment-complete-* 2>/dev/null || true"
  );

  // Try to copy Augment auth files from the host machine
  try {
    // Try to read existing Augment auth files from the host's home directory
    // Augment stores auth in ~/.augment/auth.json typically
    const authContent = await readFile(
      `${homedir()}/.augment/auth.json`,
      "utf-8"
    );

    // Validate that it's valid JSON
    JSON.parse(authContent);

    files.push({
      destinationPath: "$HOME/.augment/auth.json",
      contentBase64: Buffer.from(authContent).toString("base64"),
      mode: "600",
    });
  } catch {
    console.warn("No Augment auth.json found in host ~/.augment/");
  }

  // Also try to copy any config files
  try {
    const configContent = await readFile(
      `${homedir()}/.augment/config.json`,
      "utf-8"
    );

    // Validate that it's valid JSON
    JSON.parse(configContent);

    files.push({
      destinationPath: "$HOME/.augment/config.json",
      contentBase64: Buffer.from(configContent).toString("base64"),
      mode: "644",
    });
  } catch {
    // Config file is optional
  }

  // Create the stop hook script in /root/lifecycle (outside git repo)
  const stopHookScript = `#!/bin/bash
# Augment Code stop hook for cmux task completion detection
# This script is called when Augment Code finishes responding

# Log to multiple places for debugging
LOG_FILE="/root/lifecycle/augment-hook.log"

echo "[CMUX Stop Hook] Script started at $(date)" >> "$LOG_FILE"
echo "[CMUX Stop Hook] CMUX_TASK_RUN_ID=\${CMUX_TASK_RUN_ID}" >> "$LOG_FILE"
echo "[CMUX Stop Hook] PWD=$(pwd)" >> "$LOG_FILE"
echo "[CMUX Stop Hook] All env vars:" >> "$LOG_FILE"
env | grep -E "(CMUX|AUGMENT|TASK)" >> "$LOG_FILE" 2>&1

# Create a completion marker file that cmux can detect
COMPLETION_MARKER="/root/lifecycle/augment-complete-\${CMUX_TASK_RUN_ID:-unknown}"
echo "$(date +%s)" > "$COMPLETION_MARKER"

# Log success
echo "[CMUX Stop Hook] Created marker file: $COMPLETION_MARKER" >> "$LOG_FILE"
ls -la "$COMPLETION_MARKER" >> "$LOG_FILE" 2>&1

# Also log to stderr for visibility
echo "[CMUX Stop Hook] Task completed for task run ID: \${CMUX_TASK_RUN_ID:-unknown}" >&2
echo "[CMUX Stop Hook] Created marker file: $COMPLETION_MARKER" >&2

# Always allow Augment to stop (don't block)
exit 0`;

  // Add stop hook script to files array
  files.push({
    destinationPath: "/root/lifecycle/augment/stop-hook.sh",
    contentBase64: Buffer.from(stopHookScript).toString("base64"),
    mode: "755",
  });

  // Log the files for debugging
  startupCommands.push(
    "echo '[CMUX] Created Augment hook files in /root/lifecycle:' && ls -la /root/lifecycle/augment/"
  );
  startupCommands.push(
    "echo '[CMUX] Augment config in ~/.augment:' && ls -la /root/.augment/"
  );

  return { files, env, startupCommands };
}
