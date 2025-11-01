import type { ProviderRequirementsContext } from "../../agentConfig";

export async function checkClaudeRequirements(
  context?: ProviderRequirementsContext,
): Promise<string[]> {
  const { access } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");
  const { exec } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execAsync = promisify(exec);
  
  const missing: string[] = [];
  const hasApiKey = Boolean(context?.apiKeys?.ANTHROPIC_API_KEY?.trim());
  const homeDir = homedir();

  let hasClaudeJson = true;
  try {
    await access(join(homeDir, ".claude.json"));
  } catch {
    hasClaudeJson = false;
  }

  if (!hasClaudeJson && !hasApiKey) {
    missing.push(".claude.json file or ANTHROPIC_API_KEY");
  }

  let hasCredentials = hasApiKey;

  if (!hasCredentials) {
    try {
      await access(join(homeDir, ".claude", ".credentials.json"));
      hasCredentials = true;
    } catch {
      // No local credentials file
    }
  }

  if (!hasCredentials) {
    // Check for API key in keychain - try both Claude Code and Claude Code-credentials
    try {
      await execAsync(
        "security find-generic-password -a $USER -w -s 'Claude Code'",
      );
      hasCredentials = true;
    } catch {
      try {
        await execAsync(
          "security find-generic-password -a $USER -w -s 'Claude Code-credentials'",
        );
        hasCredentials = true;
      } catch {
        // Neither keychain entry found
      }
    }
  }

  if (!hasCredentials) {
    missing.push(
      "Claude credentials (no .credentials.json, keychain entry, or ANTHROPIC_API_KEY)",
    );
  }

  return missing;
}
