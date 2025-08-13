import type { EnvironmentResult } from "../common/environment-result.js";

export async function getQwenCodeEnvironment(): Promise<EnvironmentResult> {
  const { readFile, access } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { join, basename } = await import("node:path");
  const { Buffer } = await import("node:buffer");

  const files: EnvironmentResult["files"] = [];
  const env: Record<string, string> = {};
  const startupCommands: string[] = [];

  // Ensure config directories exist in container
  startupCommands.push("mkdir -p ~/.gemini");
  startupCommands.push("mkdir -p ~/.qwen");

  const home = homedir();

  async function tryCopy(srcPath: string, destPath: string, mode = "600") {
    try {
      await access(srcPath);
      const content = await readFile(srcPath, "utf-8");
      files.push({ destinationPath: destPath, contentBase64: Buffer.from(content).toString("base64"), mode });
      return true;
    } catch {
      return false;
    }
  }

  // Copy OAuth creds if present
  await tryCopy(join(home, ".gemini", "oauth_creds.json"), "$HOME/.gemini/oauth_creds.json", "600");
  await tryCopy(join(home, ".gemini", "mcp-oauth-tokens.json"), "$HOME/.gemini/mcp-oauth-tokens.json", "600");
  await tryCopy(join(home, ".qwen", "oauth_creds.json"), "$HOME/.qwen/oauth_creds.json", "600");

  // If GOOGLE_APPLICATION_CREDENTIALS points to a file, copy it and set env var to container path
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    const localPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;
    try {
      await access(localPath!);
      const fileName = basename(localPath!);
      const dest = `$HOME/.gemini/${fileName}`;
      const content = await readFile(localPath!, "utf-8");
      files.push({ destinationPath: dest, contentBase64: Buffer.from(content).toString("base64"), mode: "600" });
      env.GOOGLE_APPLICATION_CREDENTIALS = dest;
    } catch {
      // ignore if not found
    }
  }

  // Pass through OPENAI_API_KEY if available (also provided from Convex keys)
  if (process.env.OPENAI_API_KEY) {
    env.OPENAI_API_KEY = process.env.OPENAI_API_KEY;
  }

  return { files, env, startupCommands };
}