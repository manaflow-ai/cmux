import type { EnvironmentResult } from "../common/environment-result";

export async function applyOpenAIApiKeys(
  apiKeys: Record<string, string>
): Promise<EnvironmentResult> {
  const files: EnvironmentResult["files"] = [];
  const env: Record<string, string> = {};
  const startupCommands: string[] = [];

  const openaiApiKey = apiKeys.OPENAI_API_KEY;

  if (openaiApiKey && openaiApiKey.trim().length > 0) {
    // Ensure .codex directory exists
    startupCommands.push("mkdir -p ~/.codex");

    // Use codex login --with-api-key to authenticate properly
    // This creates the correct auth.json format that Codex CLI expects
    // Note: Codex CLI no longer picks up OPENAI_API_KEY from environment
    // Suppress output to avoid cluttering the terminal
    startupCommands.push(
      `echo "${openaiApiKey}" | bunx @openai/codex@latest login --with-api-key >/dev/null 2>&1 || true`
    );
  }

  return { files, env, startupCommands };
}
