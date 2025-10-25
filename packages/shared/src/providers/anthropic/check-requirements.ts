import type { ProviderRequirementsContext } from "../../agentConfig.js";

export async function checkClaudeRequirements(
  context?: ProviderRequirementsContext
): Promise<string[]> {
  const { access } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");
  const { exec } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execAsync = promisify(exec);

  const missing: string[] = [];

  try {
    // Check for .claude.json
    await access(join(homedir(), ".claude.json"));
  } catch {
    missing.push(".claude.json file");
  }

  let hasAuth = false;

  // Check for API key from Convex settings
  const apiKeyFromSettings = context?.apiKeys?.ANTHROPIC_API_KEY;
  if (typeof apiKeyFromSettings === "string" && apiKeyFromSettings.trim()) {
    hasAuth = true;
  }

  try {
    // Check for credentials
    const hasCredentialsFile = await access(
      join(homedir(), ".claude", ".credentials.json")
    )
      .then(() => true)
      .catch(() => false);

    if (hasCredentialsFile) {
      hasAuth = true;
    }

    if (!hasCredentialsFile && !hasAuth) {
      // Check for API key in keychain - try both Claude Code and Claude Code-credentials
      let foundInKeychain = false;

      try {
        await execAsync(
          "security find-generic-password -a $USER -w -s 'Claude Code'"
        );
        foundInKeychain = true;
      } catch {
        // Try Claude Code-credentials as fallback
        try {
          await execAsync(
            "security find-generic-password -a $USER -w -s 'Claude Code-credentials'"
          );
          foundInKeychain = true;
        } catch {
          // Neither keychain entry found
        }
      }

      if (foundInKeychain) {
        hasAuth = true;
      }

      if (!hasAuth) {
        missing.push(
          "Claude credentials (no .credentials.json, API key in settings, or API key in keychain)"
        );
      }
    }
  } catch {
    if (!hasAuth) {
      missing.push("Claude credentials");
    }
  }

  return missing;
}