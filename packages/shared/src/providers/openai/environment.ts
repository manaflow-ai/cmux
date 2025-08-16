import type { EnvironmentResult } from "../common/environment-result.js";

export async function getOpenAIEnvironment(): Promise<EnvironmentResult> {
  // These must be lazy since configs are imported into the browser
  const { readFile } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { Buffer } = await import("node:buffer");

  const files: EnvironmentResult["files"] = [];
  const env: Record<string, string> = {};
  const startupCommands: string[] = [];

  // Ensure .codex directory exists
  startupCommands.push("mkdir -p ~/.codex");
  // Ensure workspace notify sink starts clean for this run
  startupCommands.push("rm -f /root/workspace/codex-turns.jsonl || true");

  // List of files to copy from .codex directory
  const codexFiles = [
    { name: "auth.json", mode: "600" },
    { name: "config.json", mode: "644" },
    { name: "instructions.md", mode: "644" },
  ];

  // Try to copy each file
  for (const file of codexFiles) {
    try {
      const content = await readFile(
        `${homedir()}/.codex/${file.name}`,
        "utf-8"
      );
      files.push({
        destinationPath: `$HOME/.codex/${file.name}`,
        contentBase64: Buffer.from(content).toString("base64"),
        mode: file.mode,
      });
    } catch (error) {
      // File doesn't exist or can't be read, skip it
      console.warn(`Failed to read .codex/${file.name}:`, error);
    }
  }

  return { files, env, startupCommands };
}
