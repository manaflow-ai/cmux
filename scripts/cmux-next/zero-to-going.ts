#!/usr/bin/env bun
/**
 * Zero to going: how many steps and how long it takes a person to get from nothing to a working agent on cmux
 * Cloud, at each level the Start page offers (Leo, 2026-11-22: "i want all these to just be super accessible and
 * usable, from human to agent to what we expect on our end."). One harness, so the worst level can be fixed and
 * measured again with the same tool.
 *
 *   AGENT  paste one line into a coding agent; it follows the page's "If you are an agent" steps.
 *   APP    the Mac app: sign in, File > New Cloud Chat, type, Return.
 *   CLI    `cmux login`, `cmux whoami`, `cmux chat --on vm --harness claude ... --wait --json`.
 *   CHIEF  one prompt pasted to Chief in Home; Chief runs the same commands.
 *   PHONE  one prompt pasted to Chief or an agent on the Mac, then the iPhone app.
 *
 *   bun scripts/cmux-next/zero-to-going.ts --documented                    # the counted steps only, no network
 *   bun scripts/cmux-next/zero-to-going.ts --backend staging --out DIR      # counted, and the Cloud part timed
 *   bun scripts/cmux-next/zero-to-going.ts --backend staging --model real   # the person's Claude login on the machine
 *   bun scripts/cmux-next/zero-to-going.ts --backend staging --model stub   # the Cloud part alone, by hand, never the headline
 *   bun scripts/cmux-next/zero-to-going.ts --backend staging --cleanup-tag zg-…  # a workflow's always() step
 *
 * A step is one of the kinds vm-hassle.ts counts: a command (typed by the person, or by the agent or Chief working
 * for them), a wait (a command repeated until it says so, or a wait for the machine), or a physical step (only the
 * person can do it, outside the terminal: a browser sign-in, a click in the app, a card, a phone). Each step also
 * says who does it (person, or agent/Chief) and, when it applies only sometimes, when. The steps come from the Start
 * page (web/data/next-docs/pages.ts, slug `start`) and are written here by hand: change both together. The
 * documented count is every step, the conditional ones included (the worst case a person meets).
 *
 * Timing: the agent, CLI and Chief levels all get their first reply from `cmux chat --on vm --harness claude
 * --prompt '...' --wait --json`. That needs a running cmux app (its socket), so CI cannot run the command itself.
 * The measured run walks the Cloud routes behind it on a backend as the agent test account
 * (CMUX_DOGFOOD_STACK_EMAIL / CMUX_DOGFOOD_STACK_PASSWORD, password sign-in), with the helpers vm-hassle.ts
 * and the Cloud journey use: sign in, create a machine, wait until it runs and takes an exec, start a Claude agent
 * session there, send the prompt and wait for the reply; then one more turn (Chief's `cmux chat send`). Each step
 * that maps to one of these carries its time; every other step (the Mac app, a browser, a card, the phone) is
 * counted, not timed, and says so. The level's seconds are the sum of its timed steps, so they are the Cloud part
 * only, without a person's think time; the table says which steps are not in it.
 *
 * The model, one run per path, each its own rows:
 *   none  the newcomer: a fresh account and no Claude login on the machine. The default. Where the first reply is
 *         refused, the row is the refusal's own text, with the count of steps it then takes to get a reply.
 *   real  the person who signs in to Claude on the machine: the login goes as the agent's launch credential, the
 *         transfer cloud-journey-prod.yml uses (CLAUDE_CODE_OAUTH_TOKEN, a `claude setup-token` login). It also
 *         writes the model tokens the two turns used, by model, from Claude Code's transcripts on the machine.
 *   stub  the Cloud journey's model stub on the machine: the Cloud part without model latency. By hand only; its
 *         rows say "stubbed model" and are never the headline.
 *
 * Output: lines on stdout, and with --out DIR, zero-to-going.json ({meta, rows, steps, levels}) and summary.md (the
 * table and each level's steps). The machine this run made is deleted at the end, pass, fail or SIGTERM, by its
 * id; --cleanup-tag TAG deletes what a killed run with that tag left (machines named `zero to going auto TAG`).
 */
import { randomBytes, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  Api,
  type Exec,
  JOURNEY_STUB_SCRIPT,
  MODEL_STUB_PY,
  STACK,
  directExec,
  failedTurnWhy,
  http,
  launchCredentialStartProgram,
  listAllMachines,
  passwordSignIn,
  readEnvFile,
  resolveBackend,
  runPreclaimChat,
  scrub,
  sleep,
  validLogin,
  waitMachine,
} from "./cloud-journey.ts";
import type { StepKind } from "./vm-hassle.ts";

export type Level = "agent" | "app" | "cli" | "chief" | "phone";
export type Actor = "person" | "agent";
/** What a measured step runs; `none` is counted, never timed. */
export type OpName = "none" | "signIn" | "chat" | "send";

export type LevelStep = {
  kind: StepKind;
  by: Actor;
  step: string;
  ops: OpName;
  /** Only when it applies. */
  when?: string;
};

export const START_PAGE = "web/data/next-docs/pages.ts (slug start)";
export const CHAT = "cmux chat --on vm --harness claude --prompt 'Say hello in one sentence.' --wait --json";
const CHAT_HARNESS = "cmux chat --on vm --harness HARNESS --prompt 'Say hello in one sentence.' --wait --json";
const REFUSED = "the start is refused for a Cloud plan, a model connection or GitHub";
const INSTALL_APP: LevelStep[] = [
  { kind: "physical", by: "person", step: "install cmux NEXT (Getting started has the two builds)", ops: "none", when: "the app is not installed yet" },
  { kind: "physical", by: "person", step: "open cmux NEXT", ops: "none", when: "the app is not running" },
];

/** Each level's steps, from the Start page, in order. */
export const LEVELS: Record<Level, { title: string; section: string; steps: LevelStep[] }> = {
  agent: {
    title: "Point an agent at one URL",
    section: "Point an agent at this page, If you are an agent",
    steps: [
      { kind: "physical", by: "person", step: "paste the one line into Claude Code, Codex or another coding agent on the Mac", ops: "none" },
      { kind: "command", by: "agent", step: "curl -fsSL -o /tmp/update-dev-daily.sh https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/scripts/cmux-next/update-dev-daily.sh", ops: "none", when: "cmux NEXT DEV.app is missing" },
      { kind: "command", by: "agent", step: "bash /tmp/update-dev-daily.sh", ops: "none", when: "cmux NEXT DEV.app is missing" },
      { kind: "command", by: "agent", step: 'open "$HOME/Applications/cmux NEXT DEV.app"', ops: "none" },
      { kind: "wait", by: "agent", step: "cmux whoami every few seconds, up to a minute, until it answers (the app is up)", ops: "none" },
      { kind: "command", by: "agent", step: "cmux setup local", ops: "none" },
      { kind: "command", by: "agent", step: "cmux setup harness", ops: "none" },
      { kind: "physical", by: "person", step: "a sign-in `cmux setup` names that only the person can do", ops: "none", when: "a setup step names one" },
      { kind: "command", by: "agent", step: "cmux login", ops: "signIn", when: "cmux whoami shows no account" },
      { kind: "physical", by: "person", step: "finish the cmux sign-in in the browser", ops: "none", when: "cmux whoami shows no account" },
      { kind: "wait", by: "agent", step: "cmux whoami every 10 s, up to 5 minutes, until it names the account", ops: "none", when: "cmux whoami shows no account" },
      { kind: "command", by: "agent", step: CHAT, ops: "chat" },
      { kind: "physical", by: "person", step: "do the one card or Settings page the refusal names, and say it is done", ops: "none", when: REFUSED },
      { kind: "command", by: "agent", step: "cmux cloud diagnostics", ops: "none", when: "the refusal does not say what is wrong" },
      { kind: "command", by: "agent", step: `${CHAT} (again)`, ops: "none", when: REFUSED },
    ],
  },
  app: {
    title: "In the app",
    section: "In the app",
    steps: [
      ...INSTALL_APP,
      { kind: "physical", by: "person", step: "Settings > Accounts: sign in to cmux", ops: "none" },
      { kind: "physical", by: "person", step: "finish the cmux sign-in in the browser", ops: "none" },
      { kind: "physical", by: "person", step: "File > New Cloud Chat (or New Cloud Chat from the command palette)", ops: "none" },
      { kind: "physical", by: "person", step: "type what you want done and press Return", ops: "none" },
      { kind: "wait", by: "person", step: "cmux prepares a machine; the agent replies in the chat", ops: "none" },
      { kind: "physical", by: "person", step: "do the one thing the chat's card names (a Cloud plan, a model connection, GitHub)", ops: "none", when: "cmux needs something first" },
    ],
  },
  cli: {
    title: "From the CLI",
    section: "From the CLI",
    steps: [
      ...INSTALL_APP,
      { kind: "command", by: "person", step: "cmux login", ops: "signIn" },
      { kind: "physical", by: "person", step: "finish the cmux sign-in in the browser", ops: "none" },
      { kind: "command", by: "person", step: "cmux whoami", ops: "none" },
      { kind: "command", by: "person", step: CHAT, ops: "chat" },
      { kind: "physical", by: "person", step: "do the one thing the refusal names (a Cloud plan, a model connection or GitHub)", ops: "none", when: REFUSED },
      { kind: "command", by: "person", step: "cmux cloud diagnostics", ops: "none", when: "the refusal does not say what is wrong" },
      { kind: "command", by: "person", step: `${CHAT} (again)`, ops: "none", when: REFUSED },
    ],
  },
  chief: {
    title: "Through Chief",
    section: "Through Chief",
    steps: [
      ...INSTALL_APP,
      { kind: "physical", by: "person", step: "open Home, paste the prompt to Chief with HARNESS changed to claude or codex", ops: "none" },
      { kind: "command", by: "agent", step: "cmux whoami", ops: "none" },
      { kind: "command", by: "agent", step: "cmux login", ops: "signIn", when: "signed out" },
      { kind: "physical", by: "person", step: "finish the cmux sign-in in the browser", ops: "none", when: "signed out" },
      { kind: "wait", by: "agent", step: "wait while the person finishes the sign-in", ops: "none", when: "signed out" },
      { kind: "physical", by: "person", step: "say yes when Chief asks before anything that costs money", ops: "none", when: "Chief asks" },
      { kind: "command", by: "agent", step: CHAT_HARNESS, ops: "chat" },
      { kind: "command", by: "agent", step: "cmux chat send SESSION_ID 'Say it once more, shorter.' --wait", ops: "send" },
      { kind: "command", by: "agent", step: "cmux cloud connections", ops: "none", when: "the start is refused for a model connection" },
      { kind: "command", by: "agent", step: "open cmux://settings/cloud/claude", ops: "none", when: "no connection serves Cloud" },
      { kind: "physical", by: "person", step: "open the connect link and paste the code back", ops: "none", when: "no connection serves Cloud" },
      { kind: "physical", by: "person", step: "do the one card or Settings page for a Cloud plan or GitHub", ops: "none", when: "the start is refused for a Cloud plan or GitHub" },
      { kind: "command", by: "agent", step: `${CHAT_HARNESS} (again)`, ops: "none", when: REFUSED },
    ],
  },
  phone: {
    title: "From your phone",
    section: "From your phone",
    steps: [
      ...INSTALL_APP,
      { kind: "physical", by: "person", step: "paste the prompt into Chief or an agent chat in cmux on the Mac", ops: "none" },
      { kind: "command", by: "agent", step: "cmux settings get mobile.allowIPhoneConnections", ops: "none" },
      { kind: "command", by: "agent", step: "cmux cloud open-mobile-pairing", ops: "none" },
      { kind: "physical", by: "person", step: "turn iPhone connections on", ops: "none", when: "they are off" },
      { kind: "physical", by: "person", step: "install cmux on the iPhone (the app is in beta)", ops: "none" },
      { kind: "physical", by: "person", step: "sign in on the iPhone with the same cmux account", ops: "none" },
      { kind: "physical", by: "person", step: "allow the phone on the Mac when it asks", ops: "none" },
      { kind: "command", by: "agent", step: CHAT, ops: "chat" },
      { kind: "physical", by: "person", step: "on the iPhone, open that chat and send it one message", ops: "none" },
      { kind: "command", by: "agent", step: "read the chat and show the agent's answer to the phone's message", ops: "none" },
    ],
  },
};

export const LEVEL_ORDER: Level[] = ["agent", "app", "cli", "chief", "phone"];

/** Why a level's Mac or phone steps are not timed here. */
export const NOT_TIMED: Record<Level, string> = {
  agent: "the install, app launch, `cmux setup` and the person's browser sign-in need a Mac and a person",
  app: "every step is a click in the Mac app or a browser; no headless route drives New Cloud Chat",
  cli: "the install, app launch and the person's browser sign-in need a Mac and a person; `cmux whoami` needs the app's socket",
  chief: "Chief runs inside the Mac app; the install, the paste and the browser sign-in need a Mac and a person",
  phone: "the iPhone app, its beta install, the pairing and the message sent from the phone need a Mac and an iPhone",
};

export type Counts = { steps: number; command: number; wait: number; physical: number; by_person: number; conditional: number };

export function countSteps(steps: LevelStep[]): Counts {
  const c: Counts = { steps: steps.length, command: 0, wait: 0, physical: 0, by_person: 0, conditional: 0 };
  for (const s of steps) {
    c[s.kind]++;
    if (s.by === "person") c.by_person++;
    if (s.when) c.conditional++;
  }
  return c;
}

/** The fewest steps: a person with the app installed and running, signed in, and nothing refused. */
export function bestCase(steps: LevelStep[]): number {
  return steps.filter((s) => !s.when).length;
}

export type OpTiming = { ops: Exclude<OpName, "none">; ms: number; status: "pass" | "fail" | "skip"; detail: string };

export type Row = Counts & {
  level: Level;
  best_case: number;
  /** Sum of the level's timed steps on the backend; null without a run, or when one of them failed or did not run. */
  seconds: number | null;
  timed: string[];
  not_timed: string;
  /** The backend a run timed the Cloud part on, or `docs` when only counted. */
  source: string;
  error?: string;
};

export function rowsFor(timings: OpTiming[] | null, backendName: string | null): Row[] {
  return LEVEL_ORDER.map((level) => {
    const steps = LEVELS[level].steps;
    const wanted = [...new Set(steps.map((s) => s.ops).filter((o): o is Exclude<OpName, "none"> => o !== "none"))];
    const row: Row = { level, ...countSteps(steps), best_case: bestCase(steps), seconds: null, timed: wanted, not_timed: NOT_TIMED[level], source: "docs" };
    if (!timings || !wanted.length) return row;
    row.source = backendName ?? "unknown backend";
    const got = wanted.map((o) => timings.find((t) => t.ops === o));
    const failed = got.find((t) => t && t.status !== "pass");
    const missing = wanted.filter((_, i) => !got[i]);
    if (failed) row.error = `${failed.ops}: ${failed.detail}`.slice(0, 300);
    else if (missing.length) row.error = `not run: ${missing.join(", ")}`;
    else row.seconds = got.reduce((n, t) => n + t!.ms, 0) / 1000;
    return row;
  });
}

const cell = (s: string) => s.replace(/\|/g, "\\|").replace(/\n/g, " ");

export function summaryTable(rows: Row[], timings: OpTiming[] | null): string {
  const lines = [
    "| level | steps | command | wait | physical | by the person | conditional | fewest steps | Cloud part, s | not timed here | source |",
    "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|",
  ];
  for (const r of rows) {
    const secs = r.seconds !== null ? r.seconds.toFixed(1) : r.error ? `failed: ${cell(r.error).slice(0, 160)}` : r.timed.length ? "-" : "not timed";
    const timedNames = r.timed.length ? ` (timed: ${r.timed.join(" + ")})` : "";
    lines.push(`| ${LEVELS[r.level].title} | ${r.steps} | ${r.command} | ${r.wait} | ${r.physical} | ${r.by_person} | ${r.conditional} | ${r.best_case} | ${secs}${r.seconds !== null ? timedNames : ""} | ${cell(r.not_timed)} | ${r.source}${r.source === "docs" ? " (counted)" : ""} |`);
  }
  if (timings?.length) {
    lines.push("", "| timed route | ms | result | detail |", "|---|---:|---|---|");
    for (const t of timings) lines.push(`| ${t.ops} | ${t.ms} | ${t.status} | ${cell(t.detail).slice(0, 400)} |`);
  }
  return lines.join("\n");
}

export function levelsMarkdown(): string {
  const out: string[] = [];
  for (const level of LEVEL_ORDER) {
    const l = LEVELS[level];
    out.push(`**${l.title}** (${l.steps.length} steps; Start page section: ${l.section})`, "");
    l.steps.forEach((s, i) => out.push(`${i + 1}. [${s.kind}, ${s.by}] ${s.step.startsWith("cmux") || s.step.startsWith("curl") || s.step.startsWith("bash") || s.step.startsWith("open ") ? `\`${s.step}\`` : s.step}${s.when ? ` (when ${s.when})` : ""}${s.ops !== "none" ? ` [timed: ${s.ops}]` : ""}`));
    out.push("");
  }
  return out.join("\n");
}

const MACHINE_SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 };
export const PROMPT = "Say hello in one sentence.";
export const SECOND_PROMPT = "Say it once more, shorter.";
const REPLY_BUDGET_MS = 180_000;
const GUEST = 'export HOME="${HOME:-/home/cmux}"; cd "$HOME" 2>/dev/null || cd /; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ';
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
const STUB_DIR = "/home/cmux/.cmux";
const STUB_LOG = `${STUB_DIR}/zero-to-going-model-stub.log`;

/** Where the first reply's model comes from: see the header. `none` is the newcomer and the default. */
export type ModelRoute = "none" | "real" | "stub";
export const MODEL_LABEL: Record<ModelRoute, string> = {
  none: "newcomer, no Claude login",
  real: "the person's Claude login on the machine",
  stub: "stubbed model",
};

/**
 * What a newcomer does after the first reply is refused for a model connection: the steps the Start page's agent
 * level gives for a refused start, so the count is the page's own.
 */
export const recoverySteps = (): LevelStep[] => LEVELS.agent.steps.filter((s) => s.when === REFUSED || s.step === "cmux cloud diagnostics");

/**
 * The model tokens the session used so far, by model, read from Claude Code's own transcripts on the machine
 * (each assistant message's usage, once per message id). Tokens, not money: the pricing lane turns them into its caps.
 */
/** How long a machine that already answers exec may take to have its agent daemon listening. */
const DAEMON_BUDGET_MS = 90_000;

const USAGE_PY = `import glob, json, os
seen, out = set(), {}
for f in glob.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'), recursive=True):
    for line in open(f, errors='replace'):
        try:
            m = json.loads(line).get('message') or {}
        except Exception:
            continue
        u, mid = m.get('usage'), m.get('id')
        # '<synthetic>' is Claude Code's own message (a limit notice), not a model's.
        if not isinstance(u, dict) or not mid or mid in seen or m.get('model') == '<synthetic>':
            continue
        seen.add(mid)
        o = out.setdefault(str(m.get('model')), {'messages': 0, 'input': 0, 'cache_write': 0, 'cache_read': 0, 'output': 0})
        o['messages'] += 1
        o['input'] += int(u.get('input_tokens') or 0)
        o['cache_write'] += int(u.get('cache_creation_input_tokens') or 0)
        o['cache_read'] += int(u.get('cache_read_input_tokens') or 0)
        o['output'] += int(u.get('output_tokens') or 0)
print('@@usage ' + json.dumps(out, sort_keys=True))`;

async function readUsage(ctx: Ctx): Promise<string> {
  if (!ctx.exec) return "not read: no machine";
  const r = await ctx.exec(`${GUEST}python3 -I - <<'ZG_USAGE'\n${USAGE_PY}\nZG_USAGE`, 45_000).catch((e) => ({ code: -1, stdout: "", stderr: String((e as Error).message) }));
  const found = /@@usage (\{.*\})/.exec(r.stdout)?.[1];
  if (!found) return `not read: exit ${r.code} ${(r.stderr || r.stdout).slice(-160)}`;
  const by = JSON.parse(found) as Record<string, Record<string, number>>;
  const models = Object.keys(by);
  if (!models.length) return "not read: Claude Code's transcripts on the machine name no usage";
  return models.map((m) => `${m}: ${by[m].input} input, ${by[m].cache_write} cache write, ${by[m].cache_read} cache read, ${by[m].output} output tokens in ${by[m].messages} model messages`).join("; ");
}

type Ctx = {
  api: Api;
  tag: string;
  secrets: string[];
  name: string;
  machine: string | null;
  exec: Exec | null;
  model: ModelRoute;
  login: string;
  nonce: string;
  session: string;
};

/** A timed route's answer: what it saw, and harness-only time (the stub's own start) left out of its ms. */
type OpResult = { detail: string; harnessMs?: number };

async function timeOp(ops: OpTiming["ops"], timings: OpTiming[], log: (s: string) => void, secrets: string[], run: () => Promise<OpResult>): Promise<boolean> {
  const t0 = Date.now();
  try {
    const r = await run();
    const ms = Date.now() - t0 - (r.harnessMs ?? 0);
    const detail = scrub(r.detail, secrets);
    timings.push({ ops, ms, status: "pass", detail });
    log(`pass ${ops} ${ms} ms :: ${detail}`);
    return true;
  } catch (e) {
    const detail = scrub(String((e as Error).message ?? e), secrets).slice(0, 600);
    timings.push({ ops, ms: Date.now() - t0, status: "fail", detail });
    log(`FAIL ${ops} :: ${detail}`);
    return false;
  }
}

/** The Cloud journey's model stub on the machine's loopback, with Claude Code's settings pointed at it. */
async function startStub(ctx: Ctx): Promise<string> {
  const file = `${STUB_DIR}/zero-to-going-model-stub.py`;
  const script = `${STUB_DIR}/zero-to-going-model-stub.json`;
  const ready = `${STUB_DIR}/zero-to-going-model-stub.ready`;
  for (const [p, data] of [[file, readFileSync(MODEL_STUB_PY)], [script, Buffer.from(JSON.stringify(JOURNEY_STUB_SCRIPT))]] as const) {
    const w = await ctx.api.raw("POST", `/v1/cloud/machines/${ctx.machine}/fs/write`, { path: p, dataBase64: data.toString("base64"), mode: 0o644 });
    if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${p}: HTTP ${w.status} ${String(w.body?.error?.code ?? "").slice(0, 80)}`);
  }
  const r = await ctx.exec!(
    `mkdir -p ${STUB_DIR}; rm -f ${shq(STUB_LOG)} ${shq(ready)}; (nohup python3 ${shq(file)} --port 0 --script ${shq(script)} --nonce ${shq(ctx.nonce)} --log ${shq(STUB_LOG)} --ready-file ${shq(ready)} >${shq(STUB_LOG)}.out 2>&1 &); ` +
      `for i in $(seq 50); do [ -s ${shq(ready)} ] && break; sleep 0.2; done; ` +
      `port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' ${shq(ready)} 2>/dev/null); ` +
      `[ -n "$port" ] && curl -fsS -m 2 "http://127.0.0.1:$port/__stub/info" | grep -q ${shq(ctx.nonce)} || { echo stub-down; tail -5 ${shq(STUB_LOG)}.out; exit 1; }; ` +
      `echo "@@port $port"; python3 - "$port" <<'PY'\nimport json, pathlib, sys\np = pathlib.Path('/home/cmux/.claude/settings.json')\np.parent.mkdir(parents=True, exist_ok=True)\nc = json.loads(p.read_text()) if p.exists() else {}\nc.setdefault('env', {})['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + sys.argv[1]\np.write_text(json.dumps(c))\nprint('stub-ready')\nPY`,
    60_000,
  );
  if (!r.stdout.includes("stub-ready")) throw new Error(`model stub: exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
  return /@@port (\d+)/.exec(r.stdout)?.[1] ?? "?";
}

/** One turn's reply: the session's last message once `acp wait` says the turn ended. */
async function awaitReply(ctx: Ctx): Promise<string> {
  const t0 = Date.now();
  let last = "";
  while (Date.now() - t0 < REPLY_BUDGET_MS) {
    const r = await ctx.exec!(`${GUEST}"$c" acp wait ${shq(ctx.session)} --timeout 20 >/dev/null 2>&1; echo "@@wait $?"; "$c" acp last ${shq(ctx.session)} 2>&1`, 45_000);
    const wait = /@@wait (\d+)/.exec(r.stdout)?.[1];
    last = r.stdout.replace(/@@wait \d+\n?/, "").trim();
    if (wait === "0" && last) return last;
    if (wait && wait !== "0" && wait !== "3") throw new Error(`acp wait exit ${wait}: ${await failedTurnWhy(ctx.exec!, ctx.session, last)}`);
  }
  throw new Error(`no reply within ${REPLY_BUDGET_MS / 1000} s; last: ${last.slice(-200)}`);
}

async function send(ctx: Ctx, text: string): Promise<void> {
  const r = await ctx.exec!(`${GUEST}printf '%s' ${shq(text)} | "$c" acp send --no-wait ${shq(ctx.session)} - 2>&1; echo "@@exit $?"`, 60_000);
  if (!/@@exit 0/.test(r.stdout)) throw new Error(`send refused: ${(r.stdout || r.stderr).slice(-300)}`);
}

/** With the stub, the reply must carry its nonce: the stub answered, not some other model. */
function checkStubReply(ctx: Ctx, last: string, tool: boolean): void {
  if (ctx.model !== "stub") return;
  const want = tool ? `Stub reply ${ctx.nonce}. The tool printed ${ctx.nonce}-tool` : `Stub reply ${ctx.nonce}.`;
  if (!last.includes(want)) throw new Error(`the reply does not carry the stub's nonce: ${last.slice(-200)}`);
}

/**
 * `cmux chat --on vm ... --wait`: a machine, running with a first exec, a Claude agent session there with the
 * person's model connection as its launch credential, the first reply. The stub's own start is harness time, left out.
 */
async function chatOp(ctx: Ctx): Promise<OpResult> {
  const t0 = Date.now();
  const v = await ctx.api.op("cloud.machine.create", { name: ctx.name, size: MACHINE_SIZE }, `${ctx.tag}-create-${randomUUID().slice(0, 8)}`);
  ctx.machine = String(v.machine.id);
  ctx.exec = directExec(ctx.api, ctx.machine, { secrets: ctx.secrets });
  const m = await waitMachine(ctx.api, ctx.machine, (x) => x.status === "running" && Boolean(x.host), 300_000);
  const runningMs = Date.now() - t0;
  let lastError = "";
  let execOk = false;
  while (Date.now() - t0 < runningMs + 120_000) {
    const r = await ctx.exec("true", 30_000).catch((e) => ({ code: -1, stdout: "", stderr: String((e as Error).message) }));
    if (r.code === 0) {
      execOk = true;
      break;
    }
    lastError = r.stderr.slice(-200);
    await sleep(2000);
  }
  if (!execOk) throw new Error(`running on ${m.host} but no exec within 120 s: ${lastError}`);
  const execMs = Date.now() - t0;
  let harnessMs = 0;
  let stubNote = "";
  if (ctx.model === "stub") {
    const s0 = Date.now();
    const port = await startStub(ctx);
    harnessMs = Date.now() - s0;
    stubNote = `; the stub's start (${harnessMs} ms, 127.0.0.1:${port}) is harness time, left out`;
  }
  if (ctx.model === "none") {
    // The newcomer: no login on the machine, the session started the plain way. A refusal is the row.
    const chat = await runPreclaimChat(ctx.exec, ctx.session, PROMPT, REPLY_BUDGET_MS);
    const recovery = recoverySteps();
    if (chat.replyMs === null) throw new Error(`refused: ${chat.replyNotJudged}. To recover: ${recovery.length} more steps, ${recovery.filter((s) => s.by === "person").length} by the person. Before it: running ${runningMs} ms, first exec ${execMs} ms, agent start ${chat.chatMs} ms`);
    return { detail: `${ctx.machine}: running ${runningMs} ms, first exec ${execMs} ms, agent start ${chat.chatMs} ms, first reply ${chat.replyMs} ms after the send (${MODEL_LABEL.none})` };
  }
  const a0 = Date.now();
  // A machine can answer its first exec before its agent daemon listens: that start says so and is asked again,
  // and the wait counts as agent start, as it would for the person.
  const startProgram = `${GUEST}${launchCredentialStartProgram(ctx.session, "claude", "CLAUDE_CODE_OAUTH_TOKEN", ctx.login)}`;
  let started = await ctx.exec(startProgram, 120_000);
  while (/@@nostart no acpmux socket/.test(started.stdout) && Date.now() - a0 < DAEMON_BUDGET_MS) {
    // Any `acp` command brings the daemon up when nothing has yet (the newcomer path's `acp ensure` does the same).
    await ctx.exec(`${GUEST}"$c" acp ls >/dev/null 2>&1; true`, 60_000).catch(() => undefined);
    await sleep(1000);
    started = await ctx.exec(startProgram, 120_000);
  }
  if (started.code !== 0 || !/@@session \S+/.test(started.stdout)) throw new Error(`agent start refused: ${scrub(started.stdout.slice(-300) || started.stderr.slice(-300), [ctx.login])}`);
  const agentMs = Date.now() - a0;
  const s1 = Date.now();
  await send(ctx, PROMPT);
  const last = await awaitReply(ctx);
  checkStubReply(ctx, last, true);
  const replyMs = Date.now() - s1;
  return {
    detail: `${ctx.machine}: running ${runningMs} ms, first exec ${execMs} ms, agent start ${agentMs} ms, first reply ${replyMs} ms after the send (${MODEL_LABEL[ctx.model]})${stubNote}: ${last.slice(0, 100)}`,
    harnessMs,
  };
}

/**
 * `cmux chat send SESSION_ID '...' --wait` on the same session. `send --no-wait` returns once the prompt is queued,
 * so `acp wait` right after it can still read the session idle with the first turn's reply: the turn's prompt carries
 * a marker, and its reply is read only once `acp history` lists it (the Cloud journey's laterTurn).
 */
async function sendOp(ctx: Ctx): Promise<OpResult> {
  if (!ctx.exec) throw new Error("no machine (the chat step did not run)");
  const marker = `[zg ${ctx.tag}-2]`;
  const t0 = Date.now();
  await send(ctx, `${marker} ${SECOND_PROMPT}`);
  for (;;) {
    if (Date.now() - t0 > REPLY_BUDGET_MS) throw new Error(`the turn's prompt did not reach the session within ${REPLY_BUDGET_MS / 1000} s`);
    const r = await ctx.exec(`${GUEST}"$c" acp --json history ${shq(ctx.session)} --limit 5 2>&1`, 45_000);
    let listed: any[] = [];
    try {
      listed = JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))).turns ?? [];
    } catch {
      /* not yet readable */
    }
    if (listed.some((t: any) => typeof t?.prompt === "string" && t.prompt.startsWith(marker))) break;
    await sleep(1000);
  }
  const last = await awaitReply(ctx);
  checkStubReply(ctx, last, false);
  return { detail: `reply ${Date.now() - t0} ms after the send (${MODEL_LABEL[ctx.model]}): ${last.slice(0, 100)}` };
}

async function cleanupMachine(ctx: Ctx, log: (s: string) => void): Promise<string[]> {
  const ids = new Set<string>(ctx.machine ? [ctx.machine] : []);
  const listed = await listAllMachines((q) => ctx.api.read("cloud.machine.list", q)).catch(() => []);
  for (const m of listed) if (m?.name === ctx.name && m.status !== "deleted") ids.add(String(m.id));
  const failed: string[] = [];
  for (const id of ids) {
    try {
      await ctx.api.deleteMachine(id, `${ctx.tag}-cleanup-${id}`);
      log(`cleanup: machine ${id} deleted`);
    } catch (e) {
      failed.push(`machine ${id}: ${String((e as Error).message).slice(0, 200)}`);
    }
  }
  return failed;
}

async function cleanupTag(api: Api, tag: string, log: (s: string) => void): Promise<number> {
  if (!/^zg-[a-z0-9]+$/.test(tag)) throw new Error(`--cleanup-tag ${tag}: a zg-… tag`);
  const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
  const mine = rows.filter((m) => typeof m?.name === "string" && m.name === `zero to going auto ${tag}` && m.status !== "deleted");
  let failed = 0;
  for (const m of mine) {
    await api.deleteMachine(m.id, `${tag}-tagclean-${m.id}`).then(() => log(`cleanup-tag: machine ${m.id} deleted`), (e) => { failed++; log(`cleanup-tag: machine ${m.id} ${String(e.message).slice(0, 200)}`); });
  }
  log(`cleanup-tag ${tag}: ${mine.length} machines, ${failed} failures`);
  return failed ? 1 : 0;
}

function argValue(flag: string, argv: string[]): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

function write(outDir: string | null, timings: OpTiming[] | null, meta: Record<string, string>): string {
  const rows = rowsFor(timings, meta.backend ? `${meta.backend}, ${meta.model}` : null);
  const md = [
    `## Zero to going${meta.backend ? ` on \`${meta.backend}\`` : " (counted from the Start page)"}`,
    "",
    '> Leo, 2026-11-22: "i want all these to just be super accessible and usable, from human to agent to what we expect on our end."',
    "",
    summaryTable(rows, timings),
    "",
    `steps: every step of the level as the Start page gives it (${START_PAGE}), the conditional ones included. by the person: the steps only the person can do or that the person types; the rest the agent or Chief runs. fewest steps: the app installed and running, already signed in, nothing refused. Cloud part: the level's timed steps (sign-in, then the routes behind \`cmux chat --on vm ... --wait\`, then Chief's second turn) on the backend as the agent test account, without a person's think time; never the Mac or phone steps. source names the model that replied: with the stubbed model the time has no model latency; either way the harness gave the agent its Claude login, a step a fresh account does by hand first (connect Claude for Cloud).`,
    "",
    ...(meta.backend ? [`After a first reply refused for a model connection: ${recoverySteps().length} more steps, ${recoverySteps().filter((r) => r.by === "person").length} by the person (${recoverySteps().map((r) => `${r.by}: ${r.step}`).join("; ")}).`, ""] : []),
    ...(meta.usage ? [`Model tokens for the two turns (\`${PROMPT}\`, \`${SECOND_PROMPT}\`): ${meta.usage}.`, ""] : []),
    "<details><summary>The steps of each level</summary>",
    "",
    levelsMarkdown(),
    "</details>",
    "",
  ].join("\n");
  if (outDir) {
    writeFileSync(path.join(outDir, "zero-to-going.json"), `${JSON.stringify({ meta, rows, steps: timings ?? [], recovery: recoverySteps(), levels: LEVELS }, null, 2)}\n`);
    writeFileSync(path.join(outDir, "summary.md"), md);
  }
  return md;
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("*/")[0]);
    return 0;
  }
  const outArg = argValue("--out", argv);
  const outDir = outArg ? path.resolve(outArg) : null;
  if (outDir) mkdirSync(outDir, { recursive: true });
  if (argv.includes("--documented")) {
    console.log(write(outDir, null, {}));
    return 0;
  }
  const backend = resolveBackend(argValue("--backend", argv) ?? "staging", argValue("--api", argv), argValue("--stack", argv));
  const credFile = argValue("--credentials", argv);
  const creds = credFile ? readEnvFile(readFileSync(credFile, "utf8")) : {};
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL ?? creds.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD ?? creds.CMUX_DOGFOOD_STACK_PASSWORD;
  const team = argValue("--team", argv) ?? process.env.CMUX_JOURNEY_TEAM ?? undefined;
  const secrets: string[] = password ? [password] : [];
  const log = (s: string) => console.log(scrub(s, secrets));
  const api = new Api(backend.api, team);
  if (!email || !password) {
    log("no agent test account (CMUX_DOGFOOD_STACK_EMAIL / CMUX_DOGFOOD_STACK_PASSWORD): the counted steps only");
    console.log(write(outDir, null, {}));
    return 0;
  }
  const cleanupTagArg = argValue("--cleanup-tag", argv);
  if (cleanupTagArg !== undefined) {
    const signed = await passwordSignIn(STACK[backend.stack], email, password);
    secrets.push(signed.access, signed.refresh);
    api.bearer = signed.access;
    return cleanupTag(api, cleanupTagArg, log);
  }

  const tag = argValue("--tag", argv) ?? `zg-${Date.now().toString(36)}`;
  const modelArg = argValue("--model", argv) ?? "none";
  if (modelArg !== "none" && modelArg !== "real" && modelArg !== "stub") throw new Error(`--model ${modelArg}: none, real or stub`);
  const model: ModelRoute = modelArg;
  const login = model === "none" ? "" : model === "stub" ? `sk-ant-oat01-zerotogoingstub-${randomBytes(24).toString("hex")}` : (process.env.CLAUDE_CODE_OAUTH_TOKEN ?? creds.CLAUDE_CODE_OAUTH_TOKEN ?? "").trim();
  if (model === "real" && !validLogin("claude", login)) throw new Error("--model real: CLAUDE_CODE_OAUTH_TOKEN is not a `claude setup-token` login");
  if (login) secrets.push(login);
  const health = await http("GET", `${backend.api}/v1/health`, undefined, {}).catch(() => null);
  const meta: Record<string, string> = { backend: backend.name, api: backend.api, tag, commit: String(health?.body?.commit ?? health?.body?.version ?? "?"), team: team ?? "(personal)", model: MODEL_LABEL[model] };
  log(`zero to going on ${backend.name} (${backend.api}), tag ${tag}, ${MODEL_LABEL[model]}`);
  const timings: OpTiming[] = [];
  const ctx: Ctx = { api, tag, secrets, name: `zero to going auto ${tag}`, machine: null, exec: null, model, login, nonce: randomBytes(6).toString("hex"), session: `zg-${tag}` };
  let cleaned: Promise<string[]> | null = null;
  const cleanup = () => (cleaned ??= cleanupMachine(ctx, log));
  const onSignal = (signal: string) => {
    void cleanup().finally(() => {
      write(outDir, timings, meta);
      process.exit(signal === "SIGINT" ? 130 : 143);
    });
  };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  let failedCleanup: string[] = [];
  try {
    // `cmux login` once the person has finished the browser: the account's tokens, and the account on the backend.
    const signedIn = await timeOp("signIn", timings, log, secrets, async () => {
      const signed = await passwordSignIn(STACK[backend.stack], email, password);
      secrets.push(signed.access, signed.refresh);
      api.bearer = signed.access;
      await api.op("user.ensure", {}, `${tag}-ensure-${randomUUID().slice(0, 8)}`);
      return { detail: "password sign-in (the stand-in for the browser sign-in) and user.ensure" };
    });
    if (signedIn && (await timeOp("chat", timings, log, secrets, () => chatOp(ctx)))) await timeOp("send", timings, log, secrets, () => sendOp(ctx));
    if (model === "real" && ctx.exec) {
      meta.usage = scrub(await readUsage(ctx), secrets);
      log(`usage: ${meta.usage}`);
    }
  } finally {
    process.off("SIGTERM", onSignal);
    process.off("SIGINT", onSignal);
    failedCleanup = await cleanup();
    if (failedCleanup.length) log(`cleanup FAILED: ${failedCleanup.join("; ")} (run --cleanup-tag ${tag})`);
  }
  const md = write(outDir, timings, meta);
  console.log(md);
  // A measurement, not a gate: a failed route is in the table; only a machine left behind fails the run.
  return failedCleanup.length ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
