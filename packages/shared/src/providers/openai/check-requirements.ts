import type { ProviderRequirementsContext } from "../../agentConfig.js";

export async function checkOpenAIRequirements(
  context?: ProviderRequirementsContext
): Promise<string[]> {
  const { access } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");

  const missing: string[] = [];
  let hasAuth = false;

  // Check for API key from Convex settings
  const apiKeyFromSettings = context?.apiKeys?.OPENAI_API_KEY;
  if (typeof apiKeyFromSettings === "string" && apiKeyFromSettings.trim()) {
    hasAuth = true;
  }

  // Check for .codex/auth.json (required for Codex CLI)
  try {
    await access(join(homedir(), ".codex", "auth.json"));
    hasAuth = true;
  } catch {
    if (!hasAuth) {
      missing.push(".codex/auth.json file");
    }
  }

  // Check for .codex/config.toml (new preferred config)
  try {
    await access(join(homedir(), ".codex", "config.toml"));
    hasAuth = true;
  } catch {
    if (!hasAuth && missing.length === 0) {
      missing.push(".codex/config.toml file or API key in settings");
    } else if (!hasAuth && missing.length > 0) {
      // Update existing message to mention API key option
      missing[0] = ".codex/auth.json, .codex/config.toml, or API key in settings";
    }
  }

  return missing;
}
