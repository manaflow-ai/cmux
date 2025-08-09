import type { EnvironmentResult } from "../common/environment-result.js";

export async function getQwenEnvironment(): Promise<EnvironmentResult> {
  // These must be lazy since configs are imported into the browser
  const { readFile, stat } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { Buffer } = await import("node:buffer");
  const { join } = await import("node:path");

  const files: EnvironmentResult["files"] = [];
  const env: Record<string, string> = {};
  const startupCommands: string[] = [];

  // Ensure .qwen directory exists
  startupCommands.push("mkdir -p ~/.qwen");

  const qwenDir = join(homedir(), ".qwen");
  const geminiDir = join(homedir(), ".gemini");

  // Helper function to safely copy file
  async function copyFile(
    sourcePath: string,
    destinationPath: string,
    mode: string = "644"
  ) {
    try {
      const content = await readFile(sourcePath, "utf-8");
      files.push({
        destinationPath,
        contentBase64: Buffer.from(content).toString("base64"),
        mode,
      });
      return true;
    } catch (error) {
      // Only log if it's not a "file not found" error
      if (error instanceof Error && 'code' in error && error.code !== "ENOENT") {
        console.warn(`Failed to read ${sourcePath}:`, error);
      }
      return false;
    }
  }

  // 1. Check for OAuth credentials in ~/.qwen/oauth_creds.json
  await copyFile(
    join(qwenDir, "oauth_creds.json"),
    "$HOME/.qwen/oauth_creds.json",
    "600"
  );

  // 2. Check for OAuth credentials in ~/.gemini/oauth_creds.json (Google)
  await copyFile(
    join(geminiDir, "oauth_creds.json"),
    "$HOME/.gemini/oauth_creds.json",
    "600"
  );

  // 3. Check for MCP OAuth tokens in ~/.gemini/mcp-oauth-tokens.json
  await copyFile(
    join(geminiDir, "mcp-oauth-tokens.json"),
    "$HOME/.gemini/mcp-oauth-tokens.json",
    "600"
  );

  // 4. Check for settings file in .qwen directory
  await copyFile(join(qwenDir, "settings.json"), "$HOME/.qwen/settings.json");

  // 5. Check for .env files in multiple locations
  const envPaths = [
    join(qwenDir, ".env"),
    join(geminiDir, ".env"),
    join(homedir(), ".env"),
  ];

  for (const envPath of envPaths) {
    try {
      const content = await readFile(envPath, "utf-8");
      let filename = ".env";
      if (envPath.includes(".qwen")) {
        filename = ".qwen/.env";
      } else if (envPath.includes(".gemini")) {
        filename = ".gemini/.env";
      }
      files.push({
        destinationPath: `$HOME/${filename}`,
        contentBase64: Buffer.from(content).toString("base64"),
        mode: "600",
      });
    } catch {
      // Continue to next path
    }
  }

  // 6. Pass through relevant environment variables
  const relevantEnvVars = [
    "GOOGLE_APPLICATION_CREDENTIALS",
    "OPENAI_API_KEY",
    "QWEN_API_KEY",
    "ANTHROPIC_API_KEY",
    "GEMINI_API_KEY",
  ];

  for (const envVar of relevantEnvVars) {
    if (process.env[envVar]) {
      env[envVar] = process.env[envVar];
    }
  }

  return { files, env, startupCommands };
}