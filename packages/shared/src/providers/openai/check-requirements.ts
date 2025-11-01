import type { ProviderRequirementsContext } from "../../agentConfig";

export async function checkOpenAIRequirements(
  context?: ProviderRequirementsContext
): Promise<string[]> {
  const { access } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");

  const missing: string[] = [];
  const hasApiKey = Boolean(context?.apiKeys?.OPENAI_API_KEY?.trim());

  // If we have an API key, we can use it to authenticate Codex
  // via `codex login --with-api-key`, so auth.json is not required
  if (hasApiKey) {
    return missing;
  }

  // Otherwise, check for local authentication
  try {
    await access(join(homedir(), ".codex", "auth.json"));
  } catch {
    missing.push("Codex authentication required: either sign in locally with `codex login` or provide OPENAI_API_KEY");
  }

  return missing;
}
