import { spawn } from "node:child_process";
import { mkdirSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { AcpmuxClient, retryAgentStart } from "@mux/acpmux";
import { MUX_SESSION } from "./agents.ts";
import type { MuxPaths } from "./paths.ts";
import { MUX_SYSTEM_PROMPT } from "./prompt.ts";

/**
 * Hook settings that run `self hook <event>` (self = this bun + script).
 * `env` is baked into each command: hooks run in whatever environment the
 * claude process has (under acpmux, the daemon's), not the caller's.
 */
export function hookSettings(
  self: string[],
  env: Record<string, string> = {},
): Record<string, unknown> {
  const prefix = Object.entries(env).map(([k, v]) => `${k}=${shellQuote(v)}`);
  const command = (event: string) =>
    [
      ...(prefix.length ? ["env", ...prefix] : []),
      ...[...self, "hook", event].map(shellQuote),
    ].join(" ");
  const hook = (event: string, timeout: number) => ({
    hooks: [{ type: "command", command: command(event), timeout }],
  });
  return {
    hooks: {
      SessionStart: [hook("session-start", 30)],
      UserPromptSubmit: [hook("user-prompt-submit", 30)],
      Stop: [hook("stop", 30)],
      PreCompact: [hook("pre-compact", 600)],
    },
  };
}

export function shellQuote(value: string): string {
  return /^[A-Za-z0-9_./:@-]+$/.test(value) ? value : `'${value.replace(/'/g, `'\\''`)}'`;
}

/**
 * The mux's acpmux session directory: Claude Code reads CLAUDE.md (the mux
 * prompt) and .claude/settings.json (the memory hooks) from it, whichever
 * claude-stdio harness runs it.
 */
export function writeSessionDir(dir: string, self: string[], env: Record<string, string>): void {
  mkdirSync(join(dir, ".claude"), { recursive: true });
  writeFileSync(join(dir, "CLAUDE.md"), `${MUX_SYSTEM_PROMPT}\n`);
  writeFileSync(
    join(dir, ".claude", "settings.json"),
    `${JSON.stringify(hookSettings(self, env), null, 2)}\n`,
  );
}

/** Creates the mux session (claude-sr: our stdio Claude backend through the subrouter) unless it exists. */
export async function ensureMuxSession(
  dir: string,
  harness: string,
  policy: string,
): Promise<"created" | "exists"> {
  const client = await AcpmuxClient.connect();
  try {
    return await retryAgentStart(async () => {
      // A start that failed still leaves the named session; the next send starts its agent.
      if ((await client.sessions()).some((s) => s.name === MUX_SESSION)) return "exists" as const;
      await client.newSession({ cwd: dir, name: MUX_SESSION, harness, policy });
      return "created" as const;
    });
  } finally {
    client.close();
  }
}

/** Starts `mux supervise` in the background unless one is running (its pid file says so). */
export function ensureSupervisor(paths: MuxPaths, self: string[]): number | undefined {
  const pidFile = join(paths.home, "state", "supervisor.pid");
  try {
    const pid = Number(readFileSync(pidFile, "utf8"));
    process.kill(pid, 0);
    return undefined;
  } catch {
    // Not running.
  }
  const log = openSync(join(paths.home, "state", "supervisor.log"), "a");
  const child = spawn(self[0], [self[1], "supervise"], {
    detached: true,
    stdio: ["ignore", log, log],
    env: process.env,
  });
  child.unref();
  if (child.pid) writeFileSync(pidFile, String(child.pid));
  return child.pid;
}
