export async function checkQwenRequirements(): Promise<string[]> {
  const { stat, readFile } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");

  const missing: string[] = [];
  const qwenDir = join(homedir(), ".qwen");

  // If .qwen exists with any file, consider auth present; otherwise, require OPENAI_API_KEY via env or .env
  try {
    const s = await stat(qwenDir);
    if (!s.isDirectory()) {
      throw new Error(".qwen not a directory");
    }
  } catch {
    // .qwen missing; check for OPENAI_API_KEY in env or .env files
    const envPaths = [join(qwenDir, ".env"), join(homedir(), ".env")];
    let hasApiKey = !!process.env.OPENAI_API_KEY;
    for (const envPath of envPaths) {
      if (hasApiKey) break;
      try {
        const content = await readFile(envPath, "utf-8");
        if (content.includes("OPENAI_API_KEY=")) {
          hasApiKey = true;
          break;
        }
      } catch {
        // ignore
      }
    }
    if (!hasApiKey) {
      missing.push("Qwen authentication (no ~/.qwen or OPENAI_API_KEY found)");
    }
  }

  // Also require bun (bunx) to be present at runtime; we cannot reliably check here in browser context.
  // We skip CLI checks and allow the worker to surface errors if missing.

  return missing;
}
