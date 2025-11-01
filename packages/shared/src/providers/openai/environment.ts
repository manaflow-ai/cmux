import type {
  EnvironmentContext,
  EnvironmentResult,
} from "../common/environment-result";

export async function getOpenAIEnvironment(
  ctx: EnvironmentContext
): Promise<EnvironmentResult> {
  // These must be lazy since configs are imported into the browser
  const { readFile } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  const { Buffer } = await import("node:buffer");

  const files: EnvironmentResult["files"] = [];
  const env: Record<string, string> = {};
  const startupCommands: string[] = [];

  // Ensure .codex directory exists
  startupCommands.push("mkdir -p ~/.codex");
  // Ensure notify sink starts clean for this run; write JSONL under /root/lifecycle
  startupCommands.push("mkdir -p /root/lifecycle");
  startupCommands.push(
    "rm -f /root/workspace/.cmux/tmp/codex-turns.jsonl /root/workspace/codex-turns.jsonl /root/workspace/logs/codex-turns.jsonl /tmp/codex-turns.jsonl /tmp/cmux/codex-turns.jsonl /root/lifecycle/codex-turns.jsonl || true"
  );

  // Add a small notify handler script that appends the payload to JSONL and marks completion
  const notifyScript = `#!/usr/bin/env sh
set -eu
echo "$1" >> /root/lifecycle/codex-turns.jsonl
touch /root/lifecycle/codex-done.txt /root/lifecycle/done.txt
`;
  files.push({
    destinationPath: "/root/lifecycle/codex-notify.sh",
    contentBase64: Buffer.from(notifyScript).toString("base64"),
    mode: "755",
  });

  // List of files to copy from .codex directory
  // Note: We handle config.toml specially below to ensure required keys (e.g. notify) are present
  const codexFiles = [
    { name: "auth.json", mode: "600" },
    { name: "instructions.md", mode: "644" },
  ];

  // Track if we found auth.json locally
  let hasAuthJson = false;

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
      if (file.name === "auth.json") {
        hasAuthJson = true;
      }
    } catch (error) {
      // File doesn't exist or can't be read, skip it
      console.warn(`Failed to read .codex/${file.name}:`, error);
    }
  }

  // If no local auth.json but we have an API key, use it to login
  if (!hasAuthJson && ctx.apiKeys?.OPENAI_API_KEY) {
    const apiKey = ctx.apiKeys.OPENAI_API_KEY.trim();
    if (apiKey.length > 0) {
      // Use the --with-api-key flag to authenticate Codex
      startupCommands.push(
        `echo "${apiKey}" | bunx @openai/codex@latest login --with-api-key`
      );
    }
  }

  // Ensure config.toml exists and contains a notify hook pointing to our script
  try {
    const rawToml = await readFile(`${homedir()}/.codex/config.toml`, "utf-8");
    const hasNotify = /(^|\n)\s*notify\s*=/.test(rawToml);
    const tomlOut = hasNotify
      ? rawToml
      : `notify = ["/root/lifecycle/codex-notify.sh"]\n` + rawToml;
    files.push({
      destinationPath: `$HOME/.codex/config.toml`,
      contentBase64: Buffer.from(tomlOut).toString("base64"),
      mode: "644",
    });
  } catch (_error) {
    // No host config.toml; create a minimal one that sets notify
    const toml = `notify = ["/root/lifecycle/codex-notify.sh"]\n`;
    files.push({
      destinationPath: `$HOME/.codex/config.toml`,
      contentBase64: Buffer.from(toml).toString("base64"),
      mode: "644",
    });
  }

  return { files, env, startupCommands };
}
