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
  // `env` also goes to the session's tools, so the mux's own `mux ...` commands use its home.
  const settings = { ...hookSettings(self, env), env };
  writeFileSync(join(dir, ".claude", "settings.json"), `${JSON.stringify(settings, null, 2)}\n`);
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

interface SupervisorState {
  pid: number;
  /** The cmux control socket the supervisor relays to (from the terminal that started it). */
  cmuxSocket?: string;
}

/**
 * Starts `mux supervise` in the background unless one is running for the same
 * cmux. Run from another cmux app's terminal, it replaces the supervisor, so
 * the mux controls the app you last ran `mux up` in.
 */
export function ensureSupervisor(paths: MuxPaths, self: string[]): number | undefined {
  const stateFile = join(paths.home, "state", "supervisor.json");
  const cmuxSocket = process.env.CMUX_SOCKET_PATH;
  try {
    const state = JSON.parse(readFileSync(stateFile, "utf8")) as SupervisorState;
    process.kill(state.pid, 0);
    if (!cmuxSocket || state.cmuxSocket === cmuxSocket) return undefined;
    process.kill(state.pid, "SIGTERM");
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
  if (child.pid)
    writeFileSync(
      stateFile,
      JSON.stringify({ pid: child.pid, cmuxSocket } satisfies SupervisorState),
    );
  return child.pid;
}

/**
 * Makes this process the supervisor of record (Home's server runs it in
 * process, so it keeps the cmux terminal as an ancestor). Stops a detached one.
 */
export function claimSupervisor(paths: MuxPaths): void {
  const stateFile = join(paths.home, "state", "supervisor.json");
  try {
    const state = JSON.parse(readFileSync(stateFile, "utf8")) as SupervisorState;
    if (state.pid !== process.pid) process.kill(state.pid, "SIGTERM");
  } catch {
    // None running.
  }
  writeFileSync(
    stateFile,
    JSON.stringify({
      pid: process.pid,
      cmuxSocket: process.env.CMUX_SOCKET_PATH,
    } satisfies SupervisorState),
  );
}
