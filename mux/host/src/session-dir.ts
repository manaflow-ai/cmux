import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { McpServer } from "./acpmux-client.ts";
import type { MuxPaths } from "./paths.ts";
import { muxSystemPrompt } from "./prompt.ts";

export function shellQuote(value: string): string {
  return /^[A-Za-z0-9_./:@=-]+$/.test(value) ? value : `'${value.replace(/'/g, `'\\''`)}'`;
}

/**
 * Claude Code hook settings that run `<self> hook <event>`. `env` is baked into
 * each command: under acpmux, hooks run in the acpmux daemon's environment,
 * not the host's. (Semantics from feat-mux mux/cli/src/up.ts.)
 */
export function hookSettings(self: string[], env: Record<string, string>): Record<string, unknown> {
  const prefix = Object.entries(env).map(([k, v]) => `${k}=${shellQuote(v)}`);
  const command = (event: string) =>
    [...(prefix.length ? ["env", ...prefix] : []), ...[...self, "hook", event].map(shellQuote)].join(" ");
  const hook = (event: string, timeout: number) => ({ hooks: [{ type: "command", command: command(event), timeout }] });
  return {
    hooks: {
      SessionStart: [hook("session-start", 30)],
      UserPromptSubmit: [hook("user-prompt-submit", 30)],
      Stop: [hook("stop", 30)],
      PreCompact: [hook("pre-compact", 600)],
    },
  };
}

/** `cmux mcp serve` as an ACP stdio MCP server, when CMUX_MCP_COMMAND names the binary. */
export function cmuxMcpServers(env: Record<string, string | undefined> = process.env): McpServer[] {
  const command = env.CMUX_MCP_COMMAND;
  return command ? [{ name: "cmux", command, args: ["mcp", "serve"], env: [] }] : [];
}

/**
 * Writes the mux's acpmux session directory: CLAUDE.md (the prompt),
 * .claude/settings.json (memory hooks and the env its tools see), and a
 * `mux` launcher in $MUX_HOME/bin, which that env puts first on PATH.
 */
export function writeSessionDir(
  paths: MuxPaths,
  self: string[],
  env: Record<string, string>,
  options: { mcp: boolean },
): void {
  mkdirSync(join(paths.session, ".claude"), { recursive: true });
  writeFileSync(join(paths.session, "CLAUDE.md"), `${muxSystemPrompt(options)}\n`);
  const launcher = join(paths.bin, "mux");
  writeFileSync(launcher, `#!/bin/sh\nexec ${self.map(shellQuote).join(" ")} "$@"\n`);
  chmodSync(launcher, 0o755);
  const toolEnv = { ...env, PATH: `${paths.bin}:${process.env.PATH ?? "/usr/bin:/bin"}` };
  const settings = { ...hookSettings(self, env), env: toolEnv };
  writeFileSync(join(paths.session, ".claude", "settings.json"), `${JSON.stringify(settings, null, 2)}\n`);
}
