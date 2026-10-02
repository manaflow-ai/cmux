#!/usr/bin/env bun
// mux: Claude Code as the user's long-lived orchestrator. `mux [claude args]`
// runs claude with the mux system prompt and memory hooks; the subcommands
// below are those hooks and the memory tools.

import { spawn } from "node:child_process";
import { zoom } from "@mux/brain";
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

const paths = muxPaths();
const budget = Number(process.env.MUX_WAKE_BUDGET ?? 96);
const self = [process.execPath, import.meta.path];
const store = () => new FileMemoryStore(paths.memory);
const hookContext = (): HookContext => ({ store: store(), sessionsDir: paths.sessions, budget });

const USAGE = `mux [claude args...]          Claude Code as mux (system prompt + memory hooks)
mux memory recall <regex> [n]  exact log lines, newest first
mux memory zoom <lo-hi>        what a summary was made of
mux memory note <text>         record a fact
mux memory wake [budget]       the memory view injected at session start
mux memory path                where memory lives
mux compact                    build missing summaries now (cheap acpmux agent)
Env: MUX_HOME (~/.cmux/mux), MUX_WAKE_BUDGET (96), MUX_COMPACT_HARNESS (claude/haiku)`;

const [command, ...rest] = process.argv.slice(2);

switch (command) {
  case "hook":
    await runHook(rest[0]);
    break;
  case "memory":
    await runMemory(rest);
    break;
  case "compact":
    await runCompact();
    break;
  case "--mux-help":
    console.log(USAGE);
    break;
  default:
    await runClaude(process.argv.slice(2));
}

async function runClaude(args: string[]): Promise<never> {
  const hook = (event: string, timeout: number) => ({
    hooks: [
      { type: "command", command: [...self, "hook", event].map(shellQuote).join(" "), timeout },
    ],
  });
  const settings = {
    hooks: {
      SessionStart: [hook("session-start", 30)],
      UserPromptSubmit: [hook("user-prompt-submit", 30)],
      Stop: [hook("stop", 30)],
      PreCompact: [hook("pre-compact", 600)],
    },
  };
  const child = spawn(
    "claude",
    ["--append-system-prompt", MUX_SYSTEM_PROMPT, "--settings", JSON.stringify(settings), ...args],
    {
      stdio: "inherit",
    },
  );
  const code = await new Promise<number>((resolve) =>
    child.on("exit", (c, signal) => resolve(c ?? (signal ? 130 : 1))),
  );
  process.exit(code);
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
    case "recall": {
      const limit = Number(args[1] ?? 20);
      for (const hit of await memory.recall(args[0] ?? ".", limit))
        console.log(`#${hit.index} ${hit.line}`);
      return;
    }
    case "zoom": {
      const [lo, hi] = (args[0] ?? "").split("-").map(Number);
      if (!Number.isInteger(lo) || !Number.isInteger(hi))
        throw new Error("usage: mux memory zoom <lo-hi>");
      for (const line of await zoom(memory, { lo, hi })) console.log(line);
      return;
    }
    case "note": {
      const { toLines } = await import("@mux/brain");
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

function shellQuote(value: string): string {
  return /^[A-Za-z0-9_./:@-]+$/.test(value) ? value : `'${value.replace(/'/g, `'\\''`)}'`;
}
