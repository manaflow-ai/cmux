#!/usr/bin/env bun
// mux: the local mux brain host for cmux-next Home (plans/cmux-next/home.md
// section 4) and the `mux` CLI the mux uses from its own shell.

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { userInfo } from "node:os";
import { toLines, zoom } from "../../packages/brain/src/index.ts";
import { FileMemoryStore } from "../../packages/brain/src/file-store.ts";
import { acpmuxSocketPath } from "./acpmux-client.ts";
import { ensureAcpmuxDaemon } from "./acpmux-daemon.ts";
import { answerPermission, listAgents, promptAgent, spawnAgent } from "./agents.ts";
import { acpmuxSummarizer, compactUntilDone } from "./compactor.ts";
import { type HookContext, type HookInput, renderWake, sessionStart, stop, userPromptSubmit } from "./hooks.ts";
import { HostAlreadyRunningError, MuxHost } from "./host.ts";
import { takeLock } from "./lock.ts";
import { muxHome, muxPaths } from "./paths.ts";
import { cmuxMcpServers } from "./session-dir.ts";

const USAGE = `mux host --daemon-socket PATH [--mux-home DIR]   run the brain host (one per MUX_HOME)
mux agents spawn --name N --cwd DIR [--harness H] [--policy P] "prompt"
mux agents list | prompt NAME "text" | allow NAME [OPTION_ID] | deny NAME
mux memory recall REGEX [N] | zoom LO-HI | note "fact" | wake [BUDGET] | path
mux hook session-start|user-prompt-submit|stop|pre-compact   (Claude Code hooks; JSON on stdin)
mux compact                                                  build missing memory summaries now
Env: CMUX_DAEMON_SOCKET, MUX_HOME (~/.cmux/mux), MUX_HARNESS (claude-sr), MUX_POLICY (approve-all),
     ACPMUX_SOCKET / ACPMUX_HOME / ACPMUX_BIN, CMUX_MCP_COMMAND, MUX_WAKE_BUDGET (96),
     MUX_COMPACT_HARNESS (claude), MUX_COMPACT_MODEL (haiku)`;

/** How to run this CLI again: the compiled executable alone, or bun + this script. */
const self = import.meta.path.includes("$bunfs") ? [process.execPath] : [process.execPath, import.meta.path];

const [command, ...rest] = process.argv.slice(2);
const flags = parseFlags(rest);
const home = flags.values["mux-home"] ?? muxHome();
const paths = muxPaths(home);
const budget = Number(process.env.MUX_WAKE_BUDGET ?? 96);
const acpmuxSocket = acpmuxSocketPath();
const store = () => new FileMemoryStore(paths.memory);

try {
  switch (command) {
    case "host":
      await runHost();
      break;
    case "agents":
      await runAgents(flags.words);
      break;
    case "memory":
      await runMemory(flags.words);
      break;
    case "hook":
      await runHook(flags.words[0]);
      break;
    case "compact":
      await runCompact();
      break;
    default:
      console.log(USAGE);
      process.exit(command === "--help" || command === "help" ? 0 : 2);
  }
} catch (error) {
  console.error(`mux ${command}: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}

function parseFlags(args: string[]): { values: Record<string, string>; words: string[] } {
  const values: Record<string, string> = {};
  const words: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg.startsWith("--") && arg.includes("=")) {
      const [key, ...value] = arg.slice(2).split("=");
      values[key] = value.join("=");
    } else if (arg.startsWith("--") && i + 1 < args.length) values[arg.slice(2)] = args[++i];
    else words.push(arg);
  }
  return { values, words };
}

/** The Mac user's full name (`id -F`), else the login name. */
function fullName(): string {
  try {
    const out = Bun.spawnSync(["id", "-F"], { stdout: "pipe", stderr: "ignore" });
    const name = out.stdout.toString().trim();
    if (out.exitCode === 0 && name) return name;
  } catch {
    // Not macOS.
  }
  return userInfo().username;
}

async function runHost(): Promise<void> {
  const daemonSocket = flags.values["daemon-socket"] ?? process.env.CMUX_DAEMON_SOCKET;
  if (!daemonSocket) throw new Error("needs --daemon-socket PATH (or CMUX_DAEMON_SOCKET)");
  const passthrough = ["CMUX_SOCKET_PATH", "ACPMUX_SOCKET", "ACPMUX_HOME", "ACPMUX_BIN", "CMUX_MCP_COMMAND", "MUX_COMPACT_HARNESS", "MUX_COMPACT_MODEL", "MUX_WAKE_BUDGET"];
  const sessionEnv: Record<string, string> = { MUX_HOME: home, MUX_SESSION_NAME: "mux", CMUX_DAEMON_SOCKET: daemonSocket };
  for (const key of passthrough) if (process.env[key]) sessionEnv[key] = process.env[key]!;
  const host = new MuxHost({
    daemonSocket,
    acpmuxSocket,
    paths,
    harness: process.env.MUX_HARNESS ?? "claude-sr",
    policy: process.env.MUX_POLICY ?? "approve-all",
    displayName: fullName(),
    self,
    sessionEnv,
    mcpServers: cmuxMcpServers(),
    agentToken: readAgentToken(process.env.MUX_AGENT_TOKEN_FILE),
    startAcpmux: process.env.ACPMUX_BIN
      ? async () => {
          await ensureAcpmuxDaemon(process.env, acpmuxSocket, (line) => console.error(`mux host: ${line}`));
        }
      : undefined,
  });
  try {
    host.start();
  } catch (error) {
    if (error instanceof HostAlreadyRunningError) {
      // The app launches the host on every Home open; the running one keeps going.
      console.error(`mux host: already running for ${home}`);
      process.exit(0);
    }
    throw error;
  }
  console.error(`mux host: pid ${process.pid}, MUX_HOME ${home}, daemon ${daemonSocket}, acpmux ${acpmuxSocket}`);
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const)
    process.on(signal, () => void host.stop().then(() => process.exit(0)));
  await Promise.race([host.stoppedPromise, host.fatal]);
}

async function runAgents([verb, ...args]: string[]): Promise<void> {
  switch (verb) {
    case "spawn": {
      const prompt = args.join(" ");
      const cwd = flags.values.cwd;
      if (!cwd || !flags.values.name || !prompt)
        throw new Error('usage: mux agents spawn --name N --cwd DIR [--harness H] [--policy P] "prompt"');
      const agent = await spawnAgent(acpmuxSocket, {
        cwd,
        prompt,
        name: flags.values.name,
        harness: flags.values.harness,
        policy: flags.values.policy,
        mcpServers: cmuxMcpServers(),
      });
      console.log(`started ${agent.name} (${agent.sessionId}) in ${agent.cwd}; its result comes back as a [mux-event]`);
      return;
    }
    case "list":
      for (const a of await listAgents(acpmuxSocket))
        console.log(
          `${a.name}\t${a.status}\t${a.harness}\t${a.cwd}${a.pendingPermissions ? `\t${a.pendingPermissions} pending permission(s)` : ""}`,
        );
      return;
    case "prompt":
      if (!args[0] || args.length < 2) throw new Error('usage: mux agents prompt NAME "text"');
      await promptAgent(acpmuxSocket, args[0], args.slice(1).join(" "));
      console.log(`sent to ${args[0]}; its result comes back as a [mux-event]`);
      return;
    case "allow":
      console.log(`allowed: ${await answerPermission(acpmuxSocket, args[0], { allow: true, optionId: args[1] })}`);
      return;
    case "deny":
      console.log(`denied: ${await answerPermission(acpmuxSocket, args[0], { allow: false })}`);
      return;
    default:
      console.log(USAGE);
  }
}

async function runMemory([verb, ...args]: string[]): Promise<void> {
  const memory = store();
  switch (verb) {
    case "recall":
      for (const hit of await memory.recall(args[0] ?? ".", Number(args[1] ?? 20))) console.log(`#${hit.index} ${hit.line}`);
      return;
    case "zoom": {
      const [lo, hi] = (args[0] ?? "").split("-").map(Number);
      if (!Number.isInteger(lo) || !Number.isInteger(hi)) throw new Error("usage: mux memory zoom LO-HI");
      for (const line of await zoom(memory, { lo, hi })) console.log(line);
      return;
    }
    case "note": {
      const length = await memory.append(toLines(`${new Date().toISOString().slice(0, 16)} note: ${args.join(" ")}`));
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

async function runHook(event: string | undefined): Promise<void> {
  const input = JSON.parse(await Bun.stdin.text()) as HookInput;
  const ctx: HookContext = { store: store(), sessionsDir: paths.hookSessions, budget };
  const print = (output: unknown) => {
    if (output !== undefined) process.stdout.write(JSON.stringify(output));
  };
  switch (event) {
    case "session-start":
      return print(await sessionStart(ctx, input));
    case "user-prompt-submit":
      return print(await userPromptSubmit(ctx, input));
    case "stop": {
      const { compact } = await stop(ctx, input);
      // Compaction runs off the turn's critical path, in its own process.
      if (compact) spawn(self[0], [...self.slice(1), "compact"], { detached: true, stdio: "ignore", env: process.env }).unref();
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
  const release = takeLock(paths.compactLock);
  if (!release) return; // Another compactor is running.
  try {
    const summarizer = await acpmuxSummarizer(
      paths.compactor,
      process.env.MUX_COMPACT_HARNESS ?? "claude",
      process.env.MUX_COMPACT_MODEL ?? "haiku",
    );
    try {
      const written = await compactUntilDone(store(), budget, summarizer.summarize);
      console.error(`mux compact: ${written} summaries`);
    } finally {
      await summarizer.close();
    }
  } finally {
    release();
  }
}

/** The token file the app wrote (0600) for this host; undefined when absent. */
function readAgentToken(file: string | undefined): string | undefined {
  if (!file) return undefined;
  try {
    const token = readFileSync(file, "utf8").trim();
    return token.length > 0 ? token : undefined;
  } catch {
    return undefined;
  }
}
