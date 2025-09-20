import type {
  EnvironmentContext,
  EnvironmentResult,
} from "../common/environment-result.js";

export async function getClaudeEnvironment(
  ctx: EnvironmentContext
): Promise<EnvironmentResult> {
  // These must be lazy since configs are imported into the browser
  const { exec } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const { readFile } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { Buffer } = await import("node:buffer");
  const execAsync = promisify(exec);

  const files: EnvironmentResult["files"] = [];
  const env: Record<string, string> = {
    ANTHROPIC_BASE_URL: "https://www.cmux.dev/api/anthropic",
    ANTHROPIC_CUSTOM_HEADERS: `x-cmux-token:${ctx.taskRunJwt}`,
  };
  const startupCommands: string[] = [];

  // Prepare .claude.json
  try {
    // Try to read existing .claude.json, or create a new one
    let existingConfig = {};
    try {
      const content = await readFile(`${homedir()}/.claude.json`, "utf-8");
      existingConfig = JSON.parse(content);
    } catch {
      // File doesn't exist or is invalid, start fresh
    }

    const config = {
      ...existingConfig,
      projects: {
        "/root/workspace": {
          allowedTools: [],
          history: [],
          mcpContextUris: [],
          mcpServers: {},
          enabledMcpjsonServers: [],
          disabledMcpjsonServers: [],
          hasTrustDialogAccepted: true,
          projectOnboardingSeenCount: 0,
          hasClaudeMdExternalIncludesApproved: false,
          hasClaudeMdExternalIncludesWarningShown: false,
        },
      },
      isQualifiedForDataSharing: false,
      hasCompletedOnboarding: true,
      bypassPermissionsModeAccepted: true,
      hasAcknowledgedCostThreshold: true,
    };

    files.push({
      destinationPath: "$HOME/.claude.json",
      contentBase64: Buffer.from(JSON.stringify(config, null, 2)).toString(
        "base64"
      ),
      mode: "644",
    });
  } catch (error) {
    console.warn("Failed to prepare .claude.json:", error);
  }

  // Try to get credentials and prepare .credentials.json
  let credentialsAdded = false;
  try {
    // First try Claude Code-credentials (preferred)
    const execResult = await execAsync(
      "security find-generic-password -a $USER -w -s 'Claude Code-credentials'"
    );
    const credentialsText = execResult.stdout.trim();

    // Validate that it's valid JSON with claudeAiOauth
    const credentials = JSON.parse(credentialsText);
    if (credentials.claudeAiOauth) {
      files.push({
        destinationPath: "$HOME/.claude/.credentials.json",
        contentBase64: Buffer.from(credentialsText).toString("base64"),
        mode: "600",
      });
      credentialsAdded = true;
    }
  } catch {
    // noop
  }

  // If no credentials file was created, try to use API key via helper script (avoid env var to prevent prompts)
  if (!credentialsAdded) {
    try {
      const execResult = await execAsync(
        "security find-generic-password -a $USER -w -s 'Claude Code'"
      );
      const apiKey = execResult.stdout.trim();

      // Write the key to ~/.claude/bin/.anthropic_key with strict perms
      files.push({
        destinationPath: `$HOME/.claude/bin/.anthropic_key`,
        contentBase64: Buffer.from(apiKey).toString("base64"),
        mode: "600",
      });
    } catch {
      console.warn("No Claude API key found in keychain");
    }
  }

  // Ensure directories exist
  startupCommands.unshift("mkdir -p ~/.claude");
  startupCommands.push("mkdir -p ~/.claude/bin");
  startupCommands.push("mkdir -p /root/lifecycle/claude");

  // Clean up any previous Claude completion markers
  // This should run before the agent starts to ensure clean state
  startupCommands.push(
    "rm -f /root/lifecycle/claude-complete-* 2>/dev/null || true"
  );

  // Create the stop hook script in /root/lifecycle (outside git repo)
  const stopHookScript = `#!/bin/bash
# Claude Code stop hook for cmux task completion detection
# This script is called when Claude Code finishes responding

# Log to multiple places for debugging
LOG_FILE="/root/lifecycle/claude-hook.log"

echo "[CMUX Stop Hook] Script started at $(date)" >> "$LOG_FILE"
echo "[CMUX Stop Hook] CMUX_TASK_RUN_ID=\${CMUX_TASK_RUN_ID}" >> "$LOG_FILE"
echo "[CMUX Stop Hook] PWD=$(pwd)" >> "$LOG_FILE"
echo "[CMUX Stop Hook] All env vars:" >> "$LOG_FILE"
env | grep -E "(CMUX|CLAUDE|TASK)" >> "$LOG_FILE" 2>&1

# Create a completion marker file that cmux can detect
COMPLETION_MARKER="/root/lifecycle/claude-complete-\${CMUX_TASK_RUN_ID:-unknown}"
echo "$(date +%s)" > "$COMPLETION_MARKER"

# Log success
echo "[CMUX Stop Hook] Created marker file: $COMPLETION_MARKER" >> "$LOG_FILE"
ls -la "$COMPLETION_MARKER" >> "$LOG_FILE" 2>&1

# Also log to stderr for visibility
echo "[CMUX Stop Hook] Task completed for task run ID: \${CMUX_TASK_RUN_ID:-unknown}" >&2
echo "[CMUX Stop Hook] Created marker file: $COMPLETION_MARKER" >&2

# Always allow Claude to stop (don't block)
exit 0`;

  // Add stop hook script to files array (like Codex does) to ensure it's created before git init
  files.push({
    destinationPath: "/root/lifecycle/claude/stop-hook.sh",
    contentBase64: Buffer.from(stopHookScript).toString("base64"),
    mode: "755",
  });

  // Create settings.json with hooks configuration
  const settingsConfig: Record<string, unknown> = {
    // Configure helper to avoid env-var based prompting
    apiKeyHelper: "/root/.claude/bin/anthropic_key_helper.sh",
    hooks: {
      Stop: [
        {
          hooks: [
            {
              type: "command",
              command: "/root/lifecycle/claude/stop-hook.sh",
            },
          ],
        },
      ],
    },
  };

  // Add settings.json to files array as well
  files.push({
    destinationPath: "/root/lifecycle/claude/settings.json",
    contentBase64: Buffer.from(
      JSON.stringify(settingsConfig, null, 2)
    ).toString("base64"),
    mode: "644",
  });

  // Add apiKey helper script to read key from file
  const helperScript = `#!/bin/sh
exec cat "$HOME/.claude/bin/.anthropic_key"`;
  files.push({
    destinationPath: `$HOME/.claude/bin/anthropic_key_helper.sh`,
    contentBase64: Buffer.from(helperScript).toString("base64"),
    mode: "700",
  });

  // Create symlink from ~/.claude/settings.json to /root/lifecycle/claude/settings.json
  // Claude looks for settings in ~/.claude/settings.json
  startupCommands.push(
    "ln -sf /root/lifecycle/claude/settings.json /root/.claude/settings.json"
  );

  // Log the files for debugging
  startupCommands.push(
    "echo '[CMUX] Created Claude hook files in /root/lifecycle:' && ls -la /root/lifecycle/claude/"
  );
  startupCommands.push(
    "echo '[CMUX] Settings symlink in ~/.claude:' && ls -la /root/.claude/"
  );

  return { files, env, startupCommands };
}
