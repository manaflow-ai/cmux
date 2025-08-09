export async function checkQwenCodeRequirements(): Promise<string[]> {
  const { access } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");

  const missing: string[] = [];

  const home = homedir();
  const geminiOauth = join(home, ".gemini", "oauth_creds.json");
  const geminiMcpTokens = join(home, ".gemini", "mcp-oauth-tokens.json");
  const qwenOauth = join(home, ".qwen", "oauth_creds.json");

  const exists = async (p: string) => access(p).then(() => true).catch(() => false);

  const hasGeminiOauth = await exists(geminiOauth);
  const hasGeminiMcp = await exists(geminiMcpTokens);
  const hasQwenOauth = await exists(qwenOauth);

  let hasGoogleAppCreds = false;
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    hasGoogleAppCreds = await exists(process.env.GOOGLE_APPLICATION_CREDENTIALS);
  }

  const hasOpenAIKey = Boolean(process.env.OPENAI_API_KEY);

  if (!(hasGeminiOauth || hasGeminiMcp || hasQwenOauth || hasGoogleAppCreds || hasOpenAIKey)) {
    missing.push(
      "Qwen Code auth (no ~/.gemini/oauth_creds.json, ~/.gemini/mcp-oauth-tokens.json, ~/.qwen/oauth_creds.json, GOOGLE_APPLICATION_CREDENTIALS file, or OPENAI_API_KEY)"
    );
  }

  return missing;
}