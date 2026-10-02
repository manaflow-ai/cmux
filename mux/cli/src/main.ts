#!/usr/bin/env bun
// mux: the user's long-lived orchestrator, a Claude Code session in acpmux
// (claude-sr: our stdio backend through the subrouter) with the mux prompt and
// memory hooks, plus a supervisor that reports its agents' events back to it.

import { spawn } from "node:child_process";
import { join } from "node:path";
import { AcpmuxClient } from "@mux/acpmux";
import { toLines, zoom } from "@mux/brain";
import { acpmuxCli, lastReply, listAgents, MUX_SESSION, spawnAgent } from "./agents.ts";
import { relay, serveRelay } from "./cmux-relay.ts";
import { acpmuxSummarizer, compactUntilDone, takeLock } from "./compactor.ts";
import { FileMemoryStore } from "./file-store.ts";
import {
  renderWake,
  sessionStart,
  stop,
  userPromptSubmit,
  type HookContext,
  type HookInput,
} from "./hooks.ts";
import { muxPaths } from "./paths.ts";
import { MUX_SYSTEM_PROMPT } from "./prompt.ts";
import { Supervisor } from "./supervisor.ts";
import { ensureMuxSession, ensureSupervisor, hookSettings, writeSessionDir } from "./up.ts";

const USAGE = `mux                            start (or reattach to) your mux in acpmux
mux up                         set up the mux session and supervisor without attaching
mux home                       serve Home (the Messages view of the mux) on 127.0.0.1:47820
mux install                    put a \`mux\` launcher in ~/.local/bin (the mux's own tools need it)
mux claude [args...]           a one-off Claude Code with the mux prompt and memory hooks
mux agents spawn --cwd DIR [--name N] [--harness H] [--policy P] <prompt>
mux agents list | prompt NAME <text> | allow NAME [OPTION] | deny NAME
mux cmux <cmux args>           control the cmux app \`mux up\` last ran in (through the supervisor)
mux memory recall <regex> [n] | zoom <lo-hi> | note <text> | wake [budget] | path
mux compact                    build missing memory summaries now
Env: MUX_HOME (~/.cmux/mux), MUX_HARNESS (claude-sr), MUX_POLICY (approve-all),
     MUX_WAKE_BUDGET (96), MUX_COMPACT_HARNESS (claude/haiku)`;

const paths = muxPaths();
const budget = Number(process.env.MUX_WAKE_BUDGET ?? 96);
const self = [process.execPath, import.meta.path];
const sessionDir = join(paths.home, "session");
const relaySocket = join(paths.home, "state", "cmux.sock");
const store = () => new FileMemoryStore(paths.memory);
const hookContext = (): HookContext => ({ store: store(), sessionsDir: paths.sessions, budget });
const [command, ...rest] = process.argv.slice(2);

switch (command) {
  case undefined:
    await up();
    await run("acpmux", ["attach", MUX_SESSION]);
    break;
  case "up":
    await up({ supervisor: !rest.includes("--no-supervisor") });
    break;
  case "home":
    // The server lives in @mux/local, which depends on this package.
    await import(new URL("../../local/src/main.ts", import.meta.url).href);
    break;
  case "install":
    install();
    break;
  case "claude":
    await run("claude", [
      "--append-system-prompt",
      MUX_SYSTEM_PROMPT,
      "--settings",
      JSON.stringify(hookSettings(self, { MUX_HOME: paths.home })),
      ...rest,
    ]);
    break;
  case "supervise":
    await supervise();
    break;
  case "agents":
    await runAgents(rest);
    break;
  case "cmux": {
    const result = await relay(relaySocket, rest);
    process.stdout.write(result.stdout);
    process.stderr.write(result.stderr);
    process.exit(result.code);
  }
  case "hook":
    await runHook(rest[0]);
    break;
  case "memory":
    await runMemory(rest);
    break;
  case "compact":
    await runCompact();
    break;
  default:
    console.log(USAGE);
    process.exit(command === "--help" || command === "help" ? 0 : 2);
}

/** `supervisor: false` when the caller (Home's server) runs the supervisor itself. */
async function up(options: { supervisor: boolean } = { supervisor: true }): Promise<void> {
  writeSessionDir(sessionDir, self, { MUX_HOME: paths.home, MUX_SESSION_NAME: MUX_SESSION });
  const state = await ensureMuxSession(
    sessionDir,
    process.env.MUX_HARNESS ?? "claude-sr",
    process.env.MUX_POLICY ?? "approve-all",
  );
  const pid = options.supervisor ? ensureSupervisor(paths, self) : undefined;
  const supervisor = !options.supervisor
    ? "run by the caller"
    : pid
      ? `started (${pid})`
      : "running";
  console.error(`mux: session ${MUX_SESSION} ${state}; supervisor ${supervisor}`);
}

/** A launcher on PATH, so the mux (and you) can run `mux ...` from any shell. */
function install(): void {
  const { mkdirSync, writeFileSync, chmodSync } = require("node:fs") as typeof import("node:fs");
  const { homedir } = require("node:os") as typeof import("node:os");
  const dir = join(homedir(), ".local", "bin");
  mkdirSync(dir, { recursive: true });
  const target = join(dir, "mux");
  writeFileSync(target, `#!/bin/sh\nexec ${self.map((s) => `'${s}'`).join(" ")} "$@"\n`);
  chmodSync(target, 0o755);
  console.log(`installed ${target} -> ${self[1]}`);
}

async function run(binary: string, args: string[]): Promise<never> {
  const child = spawn(binary, args, { stdio: "inherit" });
  const code = await new Promise<number>((resolve) =>
    child.on("exit", (c, signal) => resolve(c ?? (signal ? 130 : 1))),
  );
  process.exit(code);
}

/** Runs until the daemon connection closes; `mux up` starts it again. */
async function supervise(): Promise<void> {
  const client = await AcpmuxClient.connect(undefined, "mux-supervisor");
  const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);
  const closed = new Promise<void>((resolve) => client.onClose(resolve));
  await new Supervisor(client, lastReply, log).start();
  const cmuxSocket = process.env.CMUX_SOCKET_PATH;
  if (cmuxSocket) {
    serveRelay(relaySocket);
    log(`relaying cmux commands to ${cmuxSocket}`);
  } else {
    log("no CMUX_SOCKET_PATH: run `mux up` in a cmux terminal so the mux can control cmux");
  }
  log("watching acpmux");
  await closed;
  log("acpmux connection closed");
}

async function runAgents([verb, ...args]: string[]): Promise<void> {
  switch (verb) {
    case "spawn": {
      const flags: Record<string, string> = {};
      const words: string[] = [];
      for (let i = 0; i < args.length; i++) {
        if (args[i].startsWith("--") && i + 1 < args.length) flags[args[i].slice(2)] = args[++i];
        else words.push(args[i]);
      }
      if (!flags.cwd || words.length === 0)
        throw new Error(
          "usage: mux agents spawn --cwd DIR [--name N] [--harness H] [--policy P] <prompt>",
        );
      const agent = await spawnAgent({
        cwd: flags.cwd,
        prompt: words.join(" "),
        name: flags.name,
        harness: flags.harness,
        policy: flags.policy,
      });
      console.log(
        `started ${agent.name} (${agent.sessionId}) in ${agent.cwd}; its result will come back as a [mux-event]`,
      );
      return;
    }
    case "list":
      for (const a of await listAgents())
        console.log(
          `${a.name}\t${a.status}\t${a.harness}\t${a.cwd}${a.pendingPermissions ? `\t${a.pendingPermissions} pending permission(s)` : ""}`,
        );
      return;
    case "prompt":
      process.stdout.write(
        await acpmuxCli(["send", args[0], "--no-wait", args.slice(1).join(" ")]),
      );
      return;
    case "allow":
      process.stdout.write(await acpmuxCli(["session", "allow", ...args.slice(0, 2)]));
      return;
    case "deny":
      process.stdout.write(await acpmuxCli(["session", "deny", args[0]]));
      return;
    default:
      console.log(USAGE);
  }
}

async function runHook(event: string | undefined): Promise<void> {
  const input = JSON.parse(await Bun.stdin.text()) as HookInput;
  const ctx = hookContext();
  switch (event) {
    case "session-start":
      return print(await sessionStart(ctx, input));
    case "user-prompt-submit":
      return print(await userPromptSubmit(ctx, input));
    case "stop": {
      const { compact } = await stop(ctx, input);
      // Compaction runs off the critical path, in its own process.
      if (compact)
        spawn(self[0], [self[1], "compact"], {
          detached: true,
          stdio: "ignore",
          env: process.env,
        }).unref();
      return;
    }
    case "pre-compact":
      // Before Claude Code compacts, finish the summaries the next wake view needs.
      return runCompact();
    default:
      throw new Error(`unknown hook ${event}`);
  }
}

async function runCompact(): Promise<void> {
  const release = takeLock(paths.lock);
  if (!release) return; // another compactor is running
  try {
    const summarizer = await acpmuxSummarizer(
      paths.compactor,
      process.env.MUX_COMPACT_HARNESS ?? "claude/haiku",
    );
    try {
      await compactUntilDone(store(), budget, summarizer.summarize);
    } finally {
      await summarizer.close();
    }
  } finally {
    release();
  }
}

async function runMemory([verb, ...args]: string[]): Promise<void> {
  const memory = store();
  switch (verb) {
    case "recall":
      for (const hit of await memory.recall(args[0] ?? ".", Number(args[1] ?? 20)))
        console.log(`#${hit.index} ${hit.line}`);
      return;
    case "zoom": {
      const [lo, hi] = (args[0] ?? "").split("-").map(Number);
      if (!Number.isInteger(lo) || !Number.isInteger(hi))
        throw new Error("usage: mux memory zoom <lo-hi>");
      for (const line of await zoom(memory, { lo, hi })) console.log(line);
      return;
    }
    case "note": {
      const length = await memory.append(
        toLines(`${new Date().toISOString().slice(0, 16)} note: ${args.join(" ")}`),
      );
      memory.commit("note");
      console.log(`noted (#${length - 1})`);
      return;
    }
    case "wake":
      console.log((await renderWake(memory, Number(args[0] ?? budget))).text);
      return;
    case "path":
      console.log(paths.memory);
      return;
    default:
      console.log(USAGE);
  }
}

function print(output: unknown): void {
  if (output !== undefined) process.stdout.write(JSON.stringify(output));
}
