import type { EnvironmentContext, EnvironmentResult } from "../common/environment-result.js";

export async function getQwenEnvironment(_ctx: EnvironmentContext): Promise<EnvironmentResult> {
  const { readdir, readFile, stat } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { join, relative } = await import("node:path");
  const { Buffer } = await import("node:buffer");

  const files: EnvironmentResult["files"] = [];
  const env: Record<string, string> = {};
  const startupCommands: string[] = [];

  // Ensure ~/.qwen exists in the container
  startupCommands.push("mkdir -p ~/.qwen");

  const qwenDir = join(homedir(), ".qwen");

  async function copyAllUnder(dir: string, destBase: string) {
    try {
      const entries = await readdir(dir, { withFileTypes: true });
      for (const entry of entries) {
        const srcPath = join(dir, entry.name);
        const rel = relative(qwenDir, srcPath);
        const destPath = `${destBase}/${rel}`;
        if (entry.isDirectory()) {
          // Create directory in destination at runtime
          startupCommands.push(`mkdir -p ${destBase}/${rel}`);
          await copyAllUnder(srcPath, destBase);
        } else if (entry.isFile()) {
          try {
            const content = await readFile(srcPath);
            files.push({
              destinationPath: destPath,
              contentBase64: content.toString("base64"),
              mode: "600",
            });
          } catch (e) {
            console.warn("Failed to read", srcPath, e);
          }
        }
      }
    } catch (e) {
      // If .qwen is missing, that's fine; user may rely on OPENAI_API_KEY
    }
  }

  // Recursively copy all files from host ~/.qwen to container ~/.qwen
  await copyAllUnder(qwenDir, "$HOME/.qwen");

  // Also copy a top-level .env if present (either ~/.qwen/.env or ~/.env)
  const envCandidates = [join(qwenDir, ".env"), join(homedir(), ".env")];
  for (const p of envCandidates) {
    try {
      const s = await stat(p);
      if (s.isFile()) {
        const content = await readFile(p);
        const dest = p.endsWith("/.env") ? "$HOME/.qwen/.env" : "$HOME/.env";
        files.push({ destinationPath: dest, contentBase64: content.toString("base64"), mode: "600" });
        break;
      }
    } catch {}
  }

  return { files, env, startupCommands };
}

