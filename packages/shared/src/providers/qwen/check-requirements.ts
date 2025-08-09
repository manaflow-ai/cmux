export async function checkQwenRequirements(): Promise<string[]> {
  const { access, readFile } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");
  
  const missing: string[] = [];
  const qwenDir = join(homedir(), ".qwen");
  const geminiDir = join(homedir(), ".gemini");

  // Check for authentication files in multiple locations
  const authFiles = [
    { path: join(qwenDir, "oauth_creds.json"), name: "~/.qwen/oauth_creds.json" },
    { path: join(geminiDir, "oauth_creds.json"), name: "~/.gemini/oauth_creds.json" },
    { path: join(geminiDir, "mcp-oauth-tokens.json"), name: "~/.gemini/mcp-oauth-tokens.json" },
  ];

  let hasAuth = false;
  for (const { path } of authFiles) {
    try {
      await access(path);
      hasAuth = true;
      break; // Found at least one auth file
    } catch {
      // Continue checking
    }
  }

  // Also check for API keys in environment variables
  const apiKeyEnvVars = [
    "QWEN_API_KEY",
    "OPENAI_API_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
  ];

  let hasApiKey = false;
  for (const envVar of apiKeyEnvVars) {
    if (process.env[envVar]) {
      hasApiKey = true;
      break;
    }
  }

  // Check for API keys in .env files
  if (!hasApiKey) {
    const envPaths = [
      join(qwenDir, ".env"),
      join(geminiDir, ".env"),
      join(homedir(), ".env"),
    ];

    for (const envPath of envPaths) {
      try {
        const content = await readFile(envPath, "utf-8");
        // Check for any of the API key environment variables in the file
        for (const envVar of apiKeyEnvVars) {
          if (content.includes(`${envVar}=`)) {
            hasApiKey = true;
            break;
          }
        }
        if (hasApiKey) break;
      } catch {
        // Continue checking
      }
    }
  }

  if (!hasAuth && !hasApiKey) {
    missing.push("Qwen authentication (no OAuth credentials or API key found)");
  }

  // Check for settings file (optional but recommended)
  try {
    await access(join(qwenDir, "settings.json"));
  } catch {
    // Settings file is optional, so we don't add it to missing
    // But we could add a warning if desired
  }

  return missing;
}