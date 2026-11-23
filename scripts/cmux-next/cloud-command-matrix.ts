#!/usr/bin/env bun
/**
 * The Cloud and remote command matrix: every command a person or agent runs for cmux Cloud and remote
 * machines, through the cmux and acpmux binaries a build ships, one row each with its exit code, what it
 * printed, how long it took and whether the answer is the one asked for. Leo, 2026-11-20: "well obviously
 * look at ALL the commands too esp for cloud and remote machine stuff and whatever cmux/acpmux/cmux-platform
 * stuff" (cmuxterm-hq#15841, ask-9d8bb60519, ask-84cdb99a7f).
 *
 *   bun scripts/cmux-next/cloud-command-matrix.ts --cmux target/debug/cmux-tui --acpmux target/debug/acpmux --out /tmp/m
 *   bun scripts/cmux-next/cloud-command-matrix.ts --list
 *
 * The `help` rows need no account and no app: each runs `<command> --help` with an empty HOME and no app
 * socket, the way a fresh Linux box or a headless agent meets the CLI. A row passes when it exits 0 within
 * its budget and prints help of its own: text that names the verb and is not its parent's help (`cmux vm
 * pause --help` printing all of `cmux vm --help` is the overview, not pause's help).
 *
 * The verb lists are read from the source (cloud_help.rs GROUPS, vm_short.rs VERBS, cli.rs remote actions,
 * action-surfaces.json, acpmux help_examples/host.rs), so a verb added there
 * gets a row here with nothing else to edit. --out DIR gets matrix.json and matrix.md. Exit 0 only when no
 * row failed.
 */
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const CLI = path.join(ROOT, "cmux-tui/crates/cmux-tui/src/cli");

export type Bin = "cmux" | "acpmux";
export type Row = {
  bin: Bin;
  words: string[];
  /** Lifecycle class (create/reuse, start, send, read, list, resume, pause, cleanup, help). */
  cls: string;
  /** The help this row must not just repeat (its parent scope's), as words. */
  parent?: string[];
  /** The word the help must name; default the last word before --help. */
  names?: string;
  budgetMs?: number;
};
export type Verdict = "ok" | "overview" | "error" | "empty" | "unnamed" | "timeout";
export type Result = Row & { cmd: string; code: number | null; ms: number; verdict: Verdict; head: string };

/** The `cmux cloud` verbs cloud_help.rs lists (GROUPS) plus its CLI-owned ones. */
export function cloudVerbs(src = readFileSync(path.join(CLI, "cloud_help.rs"), "utf8")): string[] {
  const groups = src.slice(src.indexOf("const GROUPS"));
  const verbs = [...groups.matchAll(/verb\(\s*"([a-z][a-z-]*)"/g)].map((m) => m[1]);
  return [...new Set([...verbs, "start-chat", "env", "keep-machine", "archive-machine"])];
}

/** The short `cmux vm` verbs (vm_short.rs VERBS). */
export function shortVerbs(src = readFileSync(path.join(CLI, "vm_short.rs"), "utf8")): string[] {
  const body = src.slice(src.indexOf("const VERBS"), src.indexOf("const API_VERBS"));
  return [...new Set([...body.matchAll(/\("([a-z]+)", "[a-z-]+"\)/g)].map((m) => m[1]))];
}

/** The VM API's own verbs under `cmux vm` (vm.rs, the cmux-vm crate), and the ones that wrap the platform API. */
const VM_API_VERBS = ["new", "show", "start", "stop", "snapshot", "creation", "key", "access", "run"];
/** `cmux cloud` verbs that are their own modules, not app actions. */
const CLOUD_MODULE_VERBS = ["secret", "team-keys", "machine-auth", "repo"];
const LINK_VERBS = ["init", "show", "peer", "serve", "ensure", "stop", "archive", "status", "dial", "chat", "sync", "project", "seed", "agent", "access", "machine", "start-chat"];
/** `cmux machine VERB`: its CLI verbs plus the app's offered `machine ...` actions. */
const MACHINE_CLI_VERBS = ["list", "add", "revoke", "rotate", "doctor", "vault"];

/**
 * `cmux remote VERB`: the CLI's own remote actions (cli.rs `remote_action_command`) plus the app's offered
 * `remote ...` actions (plans/cmux-next/action-surfaces.json, which cli/app_action_help.rs lists). Before,
 * a hand list carried `remote doctor` and `remote trust`, which no parser takes.
 */
export function remoteVerbs(
  cliSrc = readFileSync(path.join(ROOT, "cmux-tui/crates/cmux-tui/src/cli.rs"), "utf8"),
  surfaces = readFileSync(path.join(ROOT, "plans/cmux-next/action-surfaces.json"), "utf8"),
): string[] {
  const start = cliSrc.indexOf("fn remote_action_command");
  const body = cliSrc.slice(start, cliSrc.indexOf("_ => None", start));
  const cli = [...body.matchAll(/"([a-z][a-z-]*)" => Some/g)].map((m) => m[1]);
  return [...new Set([...cli, ...offeredVerbs("remote", surfaces)])];
}

/** The app's offered CLI verbs under one scope (action-surfaces.json `cli: "offered"`, `cli_name: "SCOPE VERB"`). */
export function offeredVerbs(scope: string, surfaces = readFileSync(path.join(ROOT, "plans/cmux-next/action-surfaces.json"), "utf8")): string[] {
  const doc = JSON.parse(surfaces) as { actions?: { cli?: string; cli_name?: string }[] };
  const verbs = (doc.actions ?? [])
    .filter((a) => a.cli === "offered" && a.cli_name?.startsWith(`${scope} `))
    .map((a) => a.cli_name!.slice(scope.length + 1));
  return [...new Set(verbs)].sort();
}

/**
 * `acpmux machine VERB [SUBVERB]`: every command acpmux's own help examples name (acpmux
 * cli/help_examples/host.rs), nested ones (`ticket new`, `vault keep`) included, as space-joined words.
 */
export function acpmuxMachineVerbs(
  src = readFileSync(path.join(ROOT, "cmux-tui/crates/acpmux/src/cli/help_examples/host.rs"), "utf8"),
): string[] {
  return [...new Set([...src.matchAll(/"machine ([a-z][a-z-]*(?: [a-z][a-z-]*)*)"/g)].map((m) => m[1]))].sort();
}
const ACPMUX_TOP = ["new", "run", "ensure", "send", "wait", "last", "ls", "dispatch", "resolve", "machine-auth"];

const help = (bin: Bin, words: string[], cls: string, parent?: string[], names?: string): Row => ({
  bin,
  words: [...words, "--help"],
  cls,
  parent: parent ? [...parent, "--help"] : undefined,
  names,
});

export function helpRows(): Row[] {
  const rows: Row[] = [
    help("cmux", [], "help"),
    help("cmux", ["vm"], "help", [], "vm"),
    // The overview's quick start is `cmux chat --on vm:new` (cloud_help.rs INTRO); it never named
    // `start-chat`, so a row asking for that failed on every run (Greptile P1 on #52473).
    help("cmux", ["cloud"], "help", [], "cmux chat --on"),
    help("cmux", ["machine"], "help", []),
    help("cmux", ["link"], "help", []),
    help("cmux", ["remote"], "help", []),
    help("cmux", ["chat"], "help", []),
    help("cmux", ["agents", "chat", "new"], "start", ["agents"], "--on"),
    help("cmux", ["auth", "token"], "help", [], "token"),
    help("cmux", ["whoami"], "read", [], "whoami"),
    help("cmux", ["login"], "start", [], "login"),
  ];
  for (const v of cloudVerbs()) rows.push(help("cmux", ["cloud", v], cls(v), ["cloud"]));
  for (const v of CLOUD_MODULE_VERBS) rows.push(help("cmux", ["cloud", v], cls(v), ["cloud"]));
  for (const v of shortVerbs()) {
    rows.push(help("cmux", ["vm", v], cls(v), ["vm"]));
    rows.push(help("cmux", ["cloud", v], cls(v), ["cloud"]));
  }
  for (const v of VM_API_VERBS) rows.push(help("cmux", ["vm", v], cls(v), ["vm"]));
  for (const v of new Set([...MACHINE_CLI_VERBS, ...offeredVerbs("machine")])) rows.push(help("cmux", ["machine", v], cls(v), ["machine"]));
  for (const v of LINK_VERBS) rows.push(help("cmux", ["link", v], cls(v), ["link"]));
  for (const v of remoteVerbs()) rows.push(help("cmux", ["remote", v], cls(v), ["remote"]));
  rows.push(help("acpmux", [], "help"));
  rows.push(help("acpmux", ["machine"], "help", []));
  for (const v of acpmuxMachineVerbs()) {
    const words = v.split(" ");
    // A nested verb's parent is its own group (`machine ticket new` vs `machine ticket`).
    rows.push(help("acpmux", ["machine", ...words], cls(words[0]), ["machine", ...words.slice(0, -1)]));
  }
  for (const v of ACPMUX_TOP) rows.push(help("acpmux", [v], cls(v), []));
  rows.push(help("acpmux", ["session", "move"], "resume", ["session"], "move"));
  rows.push(help("acpmux", ["hand"], "start", []));
  return rows;
}

/** A coarse lifecycle class from the verb's name, for grouping the table. */
export function cls(verb: string): string {
  if (/^(new|new-machine|create|fork|fork-machine|run|start-chat|init|add|join|enroll|enroll-self|setup|ticket|key)/.test(verb)) return "create/reuse";
  if (/^(ls|list|list-machines|files-list|peer|known-daemons|grants)$/.test(verb)) return "list";
  if (/(status|show|doctor|load|pick|machine-auth|get|whoami|dedicated|agents|resolve|last)/.test(verb)) return "read";
  if (/^(pause|pause-machine|shutdown|stop|set-idle-pause)$/.test(verb)) return "pause";
  if (/^(resume|resume-machine|start|restore|move|session)/.test(verb)) return "resume";
  if (/^(rm|kill|kill-machine|archive|archive-machine|revoke|leave|keep-machine|creation)/.test(verb)) return "cleanup";
  if (/^(exec|send|dial|chat|file-write|file-read|sync|seed|access|forward|rpc|connect|ssh|wait|dispatch)/.test(verb)) return "send";
  if (/^(start|start-session|new-workspace|new-terminal|serve|ensure)/.test(verb)) return "start";
  return "other";
}

/** First 200 characters, one line, for the table. */
const head = (text: string) => text.replace(/\s+/g, " ").trim().slice(0, 200);

export function judge(row: Row, code: number | null, out: string, parentOut: string | undefined, timedOut: boolean): Verdict {
  if (timedOut) return "timeout";
  if (code !== 0) return "error";
  if (!out.trim()) return "empty";
  if (parentOut !== undefined && row.parent && out.trim() === parentOut.trim()) return "overview";
  const name = row.names ?? row.words.filter((w) => w !== "--help").at(-1);
  if (name && !out.includes(name)) return "unnamed";
  return "ok";
}

/** The binary a row runs could not be started (missing, not executable). */
export class SpawnError extends Error {}

export function runRows(rows: Row[], bins: Record<Bin, string>): Result[] {
  const home = mkdtempSync(path.join(os.tmpdir(), "cmd-matrix-home-"));
  // A fresh box: no app socket, no config, no cmux login, no acpmux daemon to reach.
  const env: Record<string, string> = { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, LANG: "C.UTF-8", TERM: "dumb", XDG_CONFIG_HOME: path.join(home, ".config"), XDG_RUNTIME_DIR: path.join(home, "run") };
  mkdirSync(env.XDG_RUNTIME_DIR, { recursive: true });
  const cache = new Map<string, { code: number | null; out: string; ms: number; timedOut: boolean }>();
  const exec = (bin: Bin, words: string[], budgetMs: number) => {
    const key = `${bin} ${words.join(" ")}`;
    const hit = cache.get(key);
    if (hit) return hit;
    const t0 = performance.now();
    const r = spawnSync(bins[bin], words, { env, encoding: "utf8", timeout: budgetMs, input: "" });
    const ms = Math.round(performance.now() - t0);
    const timedOut = r.error !== undefined && /ETIMEDOUT/.test(String(r.error));
    // A binary that never started judged nothing: stop, never 193 `error` rows that read as a result.
    if (r.error !== undefined && !timedOut) throw new SpawnError(`${bins[bin]}: ${r.error.message}`);
    const v = { code: r.status, out: `${r.stdout ?? ""}${r.stderr ?? ""}`, ms, timedOut };
    cache.set(key, v);
    return v;
  };
  return rows.map((row) => {
    const budget = row.budgetMs ?? 10_000;
    const r = exec(row.bin, row.words, budget);
    const parent = row.parent ? exec(row.bin, row.parent, budget).out : undefined;
    return { ...row, cmd: `${row.bin} ${row.words.join(" ")}`, code: r.code, ms: r.ms, verdict: judge(row, r.code, r.out, parent, r.timedOut), head: head(r.out) };
  });
}

export function markdown(results: Result[], meta: Record<string, string>): string {
  const ok = results.filter((r) => r.verdict === "ok").length;
  const lines = [
    `## Cloud and remote command matrix: help and discovery`,
    "",
    Object.entries(meta).map(([k, v]) => `${k}: ${v}`).join("; "),
    "",
    `${ok}/${results.length} rows answer their own help (exit 0, names the verb, not the parent's text).`,
    "",
    "| command | class | exit | ms | verdict | output (start) |",
    "|---|---|---|---|---|---|",
    ...results.map((r) => `| \`${r.cmd}\` | ${r.cls} | ${r.code ?? "-"} | ${r.ms} | ${r.verdict} | ${r.head.replace(/\|/g, "\\|").slice(0, 120)} |`),
  ];
  return `${lines.join("\n")}\n`;
}

function arg(name: string, argv: string[]): string | undefined {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}

if (import.meta.main) {
  const argv = process.argv.slice(2);
  const rows = helpRows();
  if (argv.includes("--list")) {
    for (const r of rows) console.log(`${r.bin} ${r.words.join(" ")}\t${r.cls}`);
    process.exit(0);
  }
  const bins = { cmux: arg("--cmux", argv) ?? process.env.CMUX_BIN ?? "cmux", acpmux: arg("--acpmux", argv) ?? process.env.ACPMUX_BIN ?? "acpmux" };
  let results: Result[];
  try {
    results = runRows(rows, bins);
  } catch (error) {
    if (!(error instanceof SpawnError)) throw error;
    console.error(`cloud-command-matrix: nothing judged: ${error.message}`);
    process.exit(2);
  }
  const rev = spawnSync("git", ["-C", ROOT, "rev-parse", "--short=12", "HEAD"], { encoding: "utf8" }).stdout.trim();
  const meta = { harness: rev || "?", host: `${os.platform()}-${os.arch()}`, rows: String(results.length) };
  const md = markdown(results, meta);
  const out = arg("--out", argv);
  if (out) {
    mkdirSync(out, { recursive: true });
    writeFileSync(path.join(out, "matrix.json"), `${JSON.stringify({ meta, results }, null, 2)}\n`);
    writeFileSync(path.join(out, "matrix.md"), md);
  }
  process.stdout.write(md);
  const failed = results.filter((r) => r.verdict !== "ok");
  console.error(`${results.length - failed.length}/${results.length} ok; failing: ${failed.map((r) => `${r.cmd} (${r.verdict})`).join(", ") || "none"}`);
  process.exit(failed.length ? 1 : 0);
}
