#!/usr/bin/env bun
/**
 * How much of a hassle a long-running NEXT Cloud VM is (Leo, 2026-11-10: "just as long as long-running VMs are
 * reliable ... are they a hassle to set up? Are they a hassle to redo? Are they a hassle to clean up?"), in steps a
 * person types and seconds, for three flows:
 *
 *   SETUP    a new machine configured by a .cmux/machine.toml (env, secret names, setup commands that clone a repo
 *            and check its tools), its secrets delivered, GitHub on it, and an agent session started there.
 *   REDO     the same machine fresh again, as after breaking it.
 *   CLEANUP  the machine gone with everything it left (snapshots, preview links), checked with list calls.
 *
 * And two degenerate legs, because long-running reliability is proven by breaking it fast and repeatedly, never by a
 * soak (Leo, 2026-11-10: "I hate soaks ... synthetically just break it fast and repeatedly ... under constraint,
 * under load, under degenerate cases"). Nothing here keeps a machine running for its own sake.
 *
 *   REDO UNDER FAULT  configured machines with an agent session, each broken on purpose at once (the agent daemon
 *                     killed, the disk filled, the machine config's state corrupted; FAULTS), then the path's REDO
 *                     steps; --fault-rounds N repeats it (default 1, at most 5). Steps and seconds as p50 / max.
 *   CLEANUP AFTER INTERRUPTED SETUP  `cmux vm new` cancelled mid-create (the client stops listening 1.5 s in, so no
 *                     id), then the person's cleanup: find it by name, rm, check it is gone; leftovers counted.
 *
 *   bun scripts/cmux-next/vm-hassle.ts --documented                     # the counted paths only, no network
 *   bun scripts/cmux-next/vm-hassle.ts --backend staging --out DIR       # measured, both paths (before, after)
 *   bun scripts/cmux-next/vm-hassle.ts --backend staging --path before   # one path
 *   bun scripts/cmux-next/vm-hassle.ts --backend staging --cleanup-tag vh-…  # a workflow's always() step
 *
 * A step is one command a person types, one wait they do by hand (`cmux vm ls` or a status file read until it
 * says so), or one thing done outside the terminal (a GitHub device-code page). Each path lists its steps with the
 * command, from the CLI's help and action catalog (cmux-action-catalog's cloud.rs, `cmux vm --help`): that list is
 * the "documented path" count, which needs no credentials. The measured run walks the same steps on a backend through
 * the routes the app's actions call (cloud.machine.*, cloud.snapshot.*, machine exec and fs/write, previews) as the
 * agent test account (CMUX_DOGFOOD_STACK_EMAIL / CMUX_DOGFOOD_STACK_PASSWORD, Stack password sign-in), timing each.
 * A wait counts only when the person would have had it: `cmux vm new` answers `pending` after 30 s, so a machine
 * that runs within 30 s costs no `vm ls` wait. Steps that need a person's own Keychain or GitHub (`vm secret set`,
 * `vm setup-github`) are counted, not timed, and say so. The secret delivery is emulated by writing the file the
 * sealed delivery writes (~/.config/cmux/machine-secrets.env, 0600); the config apply uploads the real applier
 * (cmux-cloud-start-core's machine_config/applier.py) and the toml, stages a request and starts it, as the app's
 * plan does.
 *
 * Paths: `before` is today's CLI. `after` uses the cuts this script measures for: `cmux vm new … --wait` (create,
 * apply the machine config, wait for it, deliver the secrets: one command) and `cmux vm redo NAME` (the same
 * machine again, from its name, size, idle setting and .cmux/machine.toml). The after path's seconds are the same
 * routes, run in the order those commands run them.
 *
 * Output: lines on stdout, and with --out DIR, vm-hassle.json ({rows, steps, documented}) and summary.md (the
 * {flow, steps, seconds, leftovers} table and each path's commands). Every machine, snapshot and preview link this
 * run made is deleted at the end, pass or fail or SIGTERM, by its exact id (the journey's leak-safe delete: retried
 * under one idempotency key while the API says it was cut off); --cleanup-tag TAG deletes what a killed run with
 * that tag left (machines named `vm hassle auto TAG…`, their snapshots).
 */
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Api, type Exec, STACK, directExec, http, listAllMachines, passwordSignIn, readEnvFile, resolveBackend, scrub, sleep, waitMachine } from "./cloud-journey.ts";

export type Flow = "setup" | "redo" | "cleanup";
export type PathName = "before" | "after";
export type StepKind = "command" | "wait" | "physical";
/** What a measured step runs (`Ops`); `none` is counted, never timed (a person's Keychain or GitHub). */
export type OpName =
  | "none"
  | "create"
  | "waitRunning"
  | "applyConfig"
  | "waitConfig"
  | "deliverSecrets"
  | "startSession"
  | "createWait"
  | "revokeLinks"
  | "deleteSnapshots"
  | "delete"
  | "verifyGone"
  | "redo";

export type PersonStep = {
  kind: StepKind;
  command: string;
  ops: OpName;
  /** Only when it applies: a wait for a create that answered `pending`, a device page without the GitHub App. */
  when?: string;
};

export const MACHINE_TOML_PATH = ".cmux/machine.toml";
const NEW = `cmux vm new --name NAME --persistent --machine-config ${MACHINE_TOML_PATH}`;
const STATUS_FILE = "/home/cmux/.cmux/machine-config/status.json";

/** The steps of each flow on each path, from the CLI's help and the action catalog (cmux-action-catalog cloud.rs). */
export const PATHS: Record<PathName, Record<Flow, PersonStep[]>> = {
  before: {
    setup: [
      { kind: "command", command: "cmux vm secret set HASSLE_SECRET", ops: "none", when: "once per [secrets] name, on this Mac" },
      { kind: "command", command: NEW, ops: "create" },
      { kind: "wait", command: "cmux vm ls (until it is running)", ops: "waitRunning", when: "the create answered pending (past 30 s)" },
      { kind: "wait", command: `cmux vm file-read --target vm:ID --path ${STATUS_FILE} (until done)`, ops: "waitConfig" },
      { kind: "command", command: "cmux vm deliver-secrets --target vm:ID", ops: "deliverSecrets" },
      { kind: "command", command: "cmux vm setup-github --target vm:ID", ops: "none" },
      { kind: "physical", command: "open the GitHub device page and type the code", ops: "none", when: "the team has not connected the cmux GitHub App" },
      { kind: "command", command: "cmux vm start-session --target vm:ID --agent claude", ops: "startSession" },
    ],
    redo: [
      { kind: "command", command: "cmux vm rm NAME --confirm", ops: "delete" },
      { kind: "command", command: `${NEW} (every flag again: the old size and idle setting are not carried)`, ops: "create" },
      { kind: "wait", command: "cmux vm ls (until it is running)", ops: "waitRunning", when: "the create answered pending (past 30 s)" },
      { kind: "wait", command: `cmux vm file-read --target vm:ID --path ${STATUS_FILE} (until done)`, ops: "waitConfig" },
      { kind: "command", command: "cmux vm deliver-secrets --target vm:ID", ops: "deliverSecrets" },
      { kind: "command", command: "cmux vm setup-github --target vm:ID", ops: "none" },
      { kind: "physical", command: "open the GitHub device page and type the code", ops: "none", when: "the team has not connected the cmux GitHub App" },
      { kind: "command", command: "cmux vm start-session --target vm:ID --agent claude", ops: "startSession" },
    ],
    cleanup: [
      { kind: "command", command: "cmux vm preview-revoke --target vm:ID --port 8080", ops: "revokeLinks", when: "once per shared port, before rm (the target is gone after)" },
      { kind: "command", command: "cmux vm delete-snapshot --target vm:ID --snapshot SNAPSHOT_ID --confirm", ops: "deleteSnapshots", when: "once per snapshot, before rm, with an id kept from snapshot-machine: no CLI verb lists snapshots" },
      { kind: "command", command: "cmux vm rm NAME --confirm", ops: "delete" },
      { kind: "wait", command: "cmux vm ls (until it is gone: rm answers before the delete is done)", ops: "verifyGone" },
    ],
  },
  after: {
    setup: [
      { kind: "command", command: "cmux vm secret set HASSLE_SECRET", ops: "none", when: "once per [secrets] name, on this Mac" },
      { kind: "command", command: `${NEW} --wait (create, apply, wait for it, deliver the secrets)`, ops: "createWait" },
      { kind: "command", command: "cmux vm setup-github --target vm:ID", ops: "none" },
      { kind: "physical", command: "open the GitHub device page and type the code", ops: "none", when: "the team has not connected the cmux GitHub App" },
      { kind: "command", command: "cmux vm start-session --target vm:ID --agent claude", ops: "startSession" },
    ],
    redo: [
      { kind: "command", command: "cmux vm redo NAME (same name, size, idle setting and .cmux/machine.toml; waits and delivers)", ops: "redo" },
      { kind: "command", command: "cmux vm setup-github --target vm:ID", ops: "none" },
      { kind: "physical", command: "open the GitHub device page and type the code", ops: "none", when: "the team has not connected the cmux GitHub App" },
      { kind: "command", command: "cmux vm start-session --target vm:ID --agent claude", ops: "startSession" },
    ],
    cleanup: [
      { kind: "command", command: "cmux vm preview-revoke --target vm:ID --port 8080", ops: "revokeLinks", when: "once per shared port, before rm (the target is gone after)" },
      { kind: "command", command: "cmux vm delete-snapshot --target vm:ID --snapshot SNAPSHOT_ID --confirm", ops: "deleteSnapshots", when: "once per snapshot, before rm, with an id kept from snapshot-machine: no CLI verb lists snapshots" },
      { kind: "command", command: "cmux vm rm NAME --confirm", ops: "delete" },
      { kind: "wait", command: "cmux vm ls (until it is gone: rm answers before the delete is done)", ops: "verifyGone" },
    ],
  },
};

export const FLOWS: Flow[] = ["setup", "redo", "cleanup"];

/** The snapshot route to redo (documented only: restore answers no id, and the snapshot stays behind). */
export const REDO_BY_SNAPSHOT: PersonStep[] = [
  { kind: "command", command: "cmux vm snapshot-machine --target vm:ID (while it was good)", ops: "none" },
  { kind: "command", command: "cmux vm restore-machine --target vm:ID --snapshot SNAPSHOT_ID", ops: "none" },
  { kind: "wait", command: "cmux vm ls (restore answers with no id: find the new machine)", ops: "none" },
  { kind: "command", command: "cmux vm rm OLD --confirm", ops: "none" },
  { kind: "command", command: "cmux vm rename NEW NAME", ops: "none" },
  { kind: "command", command: "cmux vm start-session --target vm:ID --agent claude", ops: "none" },
];

/** The documented count: every step, the conditional ones included (the worst case a person meets). */
export function documentedSteps(steps: PersonStep[]): number {
  return steps.length;
}

/** The machine.toml the measured run applies: env, one secret name, setup that clones a repo and checks its tools. */
export function machineToml(tag: string): string {
  return [
    "version = 1",
    "[env]",
    `HASSLE_TAG = "${tag}"`,
    "[secrets]",
    'names = ["HASSLE_SECRET"]',
    "[setup]",
    'run = ["rm -rf hassle-repo && git clone --depth 1 https://github.com/octocat/Hello-World.git hassle-repo", "test -s hassle-repo/README && command -v git python3 curl"]',
    "timeout_minutes = 10",
    'check = ["git -C hassle-repo log -1 --format=%h"]',
    "",
  ].join("\n");
}

/** `requests/<ms>-<id>` as the app names a request (machine_config.rs request_id). */
export function requestId(nowMs: number, nonce: string): string {
  return `${String(nowMs).padStart(13, "0")}-${nonce.slice(0, 8).toLowerCase()}`;
}

/** The status.json the applier writes, or null while it has not. */
export function configState(stdout: string): { state: string; detail: string } | null {
  const at = stdout.indexOf("{");
  if (at < 0) return null;
  try {
    const s = JSON.parse(stdout.slice(at));
    const failing = s.setup?.failing_index;
    const missing = s.secrets?.missing;
    return { state: String(s.state ?? "?"), detail: [s.state, s.error, failing !== undefined && failing !== null ? `failing_index ${failing}` : "", Array.isArray(missing) && missing.length ? `missing ${missing.join(",")}` : ""].filter(Boolean).join(" ") };
  } catch {
    return null;
  }
}

export type Row = {
  flow: Flow | "redo under fault" | "cleanup after interrupted setup";
  path: PathName;
  /** Counted from the code (every step, conditional ones included). */
  documented_steps: number;
  /** The steps the measured run met (a conditional wait only when it applied); null without a run. */
  steps: number | null;
  /** Wall time of the flow's routes; null without a run. */
  seconds: number | null;
  leftovers: string[];
  source: "staging" | "code";
  error?: string;
  /** REDO under fault: how many runs passed; `steps` and `seconds` are then their p50, these their max. */
  runs?: number;
  steps_max?: number;
  seconds_max?: number;
};

export type Measured = { flow: string; path: PathName; step: string; kind: StepKind; ops: OpName; counted: boolean; ms: number; status: "pass" | "fail" | "skip"; detail: string };

/** The leftovers of `ids` in the list answers: machines not deleted, their snapshots, their preview links. */
export function leftoversOf(ids: Set<string>, machines: any[], snapshots: any[], previews: any[]): string[] {
  const out: string[] = [];
  for (const m of machines) if (ids.has(m?.id) && m.status !== "deleted" && m.status !== "deleting") out.push(`machine ${m.id} (${m.status})`);
  for (const s of snapshots) {
    const of = s?.machine ?? s?.machine_id ?? s?.source_machine ?? s?.archive_of;
    if (ids.has(of) && s.status !== "deleted" && s.status !== "deleting") out.push(`snapshot ${s.id} of ${of} (${s.status})`);
  }
  for (const p of previews) {
    const of = p?.machine ?? p?.machine_id ?? p?.vmId;
    if (ids.has(of)) out.push(`preview ${of}:${p.port ?? "?"}${Array.isArray(p.links) && p.links.length ? ` (${p.links.length} links)` : ""}`);
  }
  return out;
}

const cell = (s: string) => s.replace(/\|/g, "\\|").replace(/\n/g, " ");

export function summaryTable(rows: Row[]): string {
  const lines = ["| flow | path | steps (code) | steps (measured) | seconds | leftovers | source |", "|---|---|---:|---:|---:|---|---|"];
  for (const r of rows) {
    const left = r.error ? `run failed: ${r.error}` : r.source === "code" ? "n/a" : r.leftovers.length ? r.leftovers.join("; ") : "none";
    const many = r.runs !== undefined;
    const steps = r.steps === null ? "-" : many ? `${r.steps} / ${r.steps_max} (p50 / max, ${r.runs} runs)` : `${r.steps}`;
    const seconds = r.seconds === null ? "-" : many ? `${r.seconds.toFixed(1)} / ${(r.seconds_max ?? 0).toFixed(1)}` : r.seconds.toFixed(1);
    const shownLeft = many && !r.error ? "n/a (each run's machines deleted by the harness)" : left;
    lines.push(`| ${r.flow} | ${r.path} | ${r.documented_steps} | ${steps} | ${seconds} | ${cell(shownLeft).slice(0, 600)} | ${r.source} |`);
  }
  return lines.join("\n");
}

export function pathsMarkdown(): string {
  const out: string[] = [];
  for (const p of ["before", "after"] as PathName[]) {
    for (const f of FLOWS) {
      out.push(`**${f}, ${p}** (${documentedSteps(PATHS[p][f])} steps)`, "");
      PATHS[p][f].forEach((s, i) => out.push(`${i + 1}. [${s.kind}] \`${s.command}\`${s.when ? ` (when ${s.when})` : ""}`));
      out.push("");
    }
  }
  out.push(`**cleanup after interrupted setup, both paths** (${documentedSteps(INTERRUPTED_CLEANUP)} steps)`, "");
  INTERRUPTED_CLEANUP.forEach((s, i) => out.push(`${i + 1}. [${s.kind}] \`${s.command}\``));
  out.push("", `**redo under fault**: the path's redo steps, after one of: ${Object.keys(FAULTS).join(", ")}`, "");
  out.push(`**redo by snapshot, before** (${documentedSteps(REDO_BY_SNAPSHOT)} steps, leaves the snapshot)`, "");
  REDO_BY_SNAPSHOT.forEach((s, i) => out.push(`${i + 1}. [${s.kind}] \`${s.command}\``));
  out.push("");
  return out.join("\n");
}

export function documentedRows(): Row[] {
  const rows: Row[] = [];
  for (const p of ["before", "after"] as PathName[]) {
    for (const f of FLOWS) rows.push({ flow: f, path: p, documented_steps: documentedSteps(PATHS[p][f]), steps: null, seconds: null, leftovers: [], source: "code" });
    rows.push({ flow: "redo under fault", path: p, documented_steps: documentedSteps(PATHS[p].redo), steps: null, seconds: null, leftovers: [], source: "code" });
    rows.push({ flow: "cleanup after interrupted setup", path: p, documented_steps: documentedSteps(INTERRUPTED_CLEANUP), steps: null, seconds: null, leftovers: [], source: "code" });
  }
  return rows;
}

/** `pending` past this: the app's `cloud new-machine` answer deadline (CloudHandlers createdMachineWait). */
const CREATE_ANSWER_MS = 30_000;
const APPLIER = fileURLToPath(new URL("../../cmux-tui/crates/cmux-cloud-start-core/src/machine_config/applier.py", import.meta.url));
const PREVIEW_PORT = 8080;

type Ctx = {
  api: Api;
  tag: string;
  secrets: string[];
  /** Every machine this run made (cleanup deletes each). */
  made: Set<string>;
  snapshots: Set<string>;
  links: { machine: string; port: number; id: string }[];
  machine: string | null;
  name: string;
  createdAt: number;
  exec: Exec | null;
  waited: boolean;
};

const MACHINE_SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 };
const keyOf = (ctx: Ctx, what: string) => `${ctx.tag}-${what}-${randomUUID().slice(0, 8)}`;

async function execOk(ctx: Ctx, command: string, timeoutMs = 60_000): Promise<string> {
  const r = await ctx.exec!(command, timeoutMs);
  if (r.code !== 0) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
  return r.stdout;
}

const ROOT = 'root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }';

/** The routes behind each step. Each returns a detail line; `create` and `redo` set ctx.machine. */
const OPS: Record<Exclude<OpName, "none">, (ctx: Ctx) => Promise<string>> = {
  async create(ctx) {
    ctx.createdAt = Date.now();
    const v = await ctx.api.op("cloud.machine.create", { name: ctx.name, size: MACHINE_SIZE }, keyOf(ctx, "create"));
    ctx.machine = String(v.machine.id);
    ctx.made.add(ctx.machine);
    ctx.exec = directExec(ctx.api, ctx.machine, { secrets: ctx.secrets });
    // --persistent: no idle pause.
    await ctx.api.op("cloud.machine.idle_policy.set", { machine: ctx.machine, idle_seconds: 0 }, keyOf(ctx, "idle"));
    // The app's create then runs the machine config on the machine it got, inside the same command.
    const running = await runningAndExec(ctx);
    const applied = await OPS.applyConfig(ctx);
    return `${ctx.machine} ${running}; ${applied}`;
  },
  async waitRunning(ctx) {
    return runningAndExec(ctx);
  },
  async applyConfig(ctx) {
    const id = requestId(Date.now(), randomUUID());
    const stage = `/tmp/vm-hassle-${ctx.tag}-${id}`;
    const write = async (file: string, data: Buffer) => {
      const w = await ctx.api.raw("POST", `/v1/cloud/machines/${ctx.machine}/fs/write`, { path: file, dataBase64: data.toString("base64"), mode: 0o644 });
      if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${file}: HTTP ${w.status} ${JSON.stringify(w.body?.error ?? "").slice(0, 200)}`);
    };
    await write(`${stage}.apply`, readFileSync(APPLIER));
    await write(`${stage}.toml`, Buffer.from(machineToml(ctx.tag)));
    const out = await execOk(ctx, applyScript(id, stage));
    return `config apply ${out.trim()} (request ${id})`;
  },
  async waitConfig(ctx) {
    const t0 = Date.now();
    let polls = 0;
    let last = "";
    while (Date.now() - t0 < 600_000) {
      polls++;
      const r = await ctx.exec!(`cat ${STATUS_FILE} 2>/dev/null || true`);
      const s = configState(r.stdout);
      if (s) last = s.detail;
      if (s?.state === "done") return `done after ${polls} reads: ${s.detail}`;
      if (s?.state === "failed") {
        const log = await ctx.exec!("tail -c 600 /home/cmux/.cmux/machine-config/setup.log 2>/dev/null || true").catch(() => null);
        throw new Error(`config failed: ${s.detail}; log ${log?.stdout ?? ""}`);
      }
      await sleep(2000);
    }
    throw new Error(`config not done after 600 s: ${last}`);
  },
  async deliverSecrets(ctx) {
    // The sealed delivery's file (cmux-remote secrets): `export NAME='value'` lines, 0600, the work user's.
    await execOk(ctx, `set -eu; ${ROOT}; h=$(getent passwd cmux | cut -d: -f6); root install -d -o cmux -g cmux -m 700 "$h/.config/cmux"; printf "export HASSLE_SECRET='%s'\\n" ${ctx.tag} > /tmp/vm-hassle-sec-${ctx.tag}; root install -o cmux -g cmux -m 600 /tmp/vm-hassle-sec-${ctx.tag} "$h/.config/cmux/machine-secrets.env"; rm -f /tmp/vm-hassle-sec-${ctx.tag}`);
    return "HASSLE_SECRET (emulated: the sealed delivery's file)";
  },
  async startSession(ctx) {
    const session = `hassle-${ctx.tag}`;
    const out = await execOk(ctx, `export HOME="\${HOME:-/home/cmux}"; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; "$c" acp ensure '${session}' -m claude --json 2>&1; echo "@@exit $?"`, 120_000);
    if (!/@@exit 0/.test(out)) throw new Error(out.slice(-300));
    return `session ${session}`;
  },
  async createWait(ctx) {
    const steps = [await OPS.create(ctx), await OPS.waitConfig(ctx), await OPS.deliverSecrets(ctx)];
    return steps.join("; ");
  },
  async revokeLinks(ctx) {
    const mine = ctx.links.filter((l) => l.machine === ctx.machine);
    for (const l of mine) {
      const r = await ctx.api.raw("DELETE", `/v1/cloud/machines/${l.machine}/previews/${l.port}/links/${l.id}`);
      if (r.status >= 300 && r.status !== 404) throw new Error(`revoke ${l.id}: HTTP ${r.status}`);
      ctx.links = ctx.links.filter((x) => x !== l);
    }
    return `${mine.length} links revoked`;
  },
  async deleteSnapshots(ctx) {
    // Only the snapshots of the machine being cleaned up that the person kept the id of: a snapshot of an
    // earlier machine of the same name (REDO's rm) has no CLI path any more.
    const v = await ctx.api.read("cloud.snapshot.list", { machine: ctx.machine });
    const rows: any[] = v?.snapshots ?? [];
    for (const s of rows) {
      await ctx.api.op("cloud.snapshot.delete", { snapshot: s.id }, keyOf(ctx, "snapdel"));
      ctx.snapshots.delete(s.id);
    }
    return `${rows.length} snapshots of ${ctx.machine} deleted`;
  },
  async delete(ctx) {
    const id = ctx.machine!;
    await ctx.api.deleteMachine(id, `${ctx.tag}-delete-${id}`);
    return `${id} delete accepted`;
  },
  async verifyGone(ctx) {
    const id = ctx.machine!;
    const m = await waitMachine(ctx.api, id, (x) => x.status === "deleted", 180_000, true);
    return `${id} ${m?.status ?? "gone"}`;
  },
  async redo(ctx) {
    // `cmux vm redo NAME`: read the machine (name, size, idle), rm it, then `new --wait` with the same.
    const old = ctx.machine!;
    const m = await ctx.api.read("cloud.machine.get", { machine: old });
    await ctx.api.deleteMachine(old, `${ctx.tag}-delete-${old}`);
    const made = await OPS.createWait(ctx);
    return `${old} (${m.size?.cpu ?? "?"} vCPU, idle ${m.idle_policy?.idle_seconds ?? "?"} s) -> ${made}`;
  },
};

/** Running with a host, and the first exec through (the app's create answer waits for both). */
async function runningAndExec(ctx: Ctx): Promise<string> {
  const m = await waitMachine(ctx.api, ctx.machine!, (x) => x.status === "running" && Boolean(x.host), 300_000);
  const t0 = Date.now();
  let lastError = "";
  while (Date.now() - t0 < 120_000) {
    try {
      await execOk(ctx, "true", 30_000);
      return `running on ${m.host}`;
    } catch (e) {
      lastError = String((e as Error).message);
      await sleep(2000);
    }
  }
  throw new Error(`running but no exec within 120 s: ${lastError}`);
}

/** The preview link and the snapshot a long-running machine collects in use (CLEANUP's leftovers to find). */
async function use(ctx: Ctx, log: (s: string) => void): Promise<void> {
  try {
    await execOk(ctx, `cd /tmp && (setsid nohup python3 -m http.server ${PREVIEW_PORT} >/dev/null 2>&1 </dev/null &) ; sleep 1; curl -fsS -m 3 -o /dev/null http://127.0.0.1:${PREVIEW_PORT}/ && echo up`);
    await ctx.api.raw("POST", `/v1/cloud/machines/${ctx.machine}/previews/refresh`, {});
    const r = await ctx.api.raw("POST", `/v1/cloud/machines/${ctx.machine}/previews/${PREVIEW_PORT}/links`, {});
    const id = linkIdOf(r.body);
    if (r.status >= 300 || !id) throw new Error(`HTTP ${r.status} ${JSON.stringify(r.body).slice(0, 200)}`);
    ctx.links.push({ machine: ctx.machine!, port: PREVIEW_PORT, id: String(id) });
    log(`use: preview link ${id} on ${ctx.machine}:${PREVIEW_PORT}`);
  } catch (e) {
    log(`use: no preview link (${String((e as Error).message).slice(0, 300)})`);
  }
  try {
    const v = await ctx.api.op("cloud.snapshot.create", { machine: ctx.machine, name: `vm hassle ${ctx.tag}` }, keyOf(ctx, "snap"));
    const id = String(v.snapshot.id);
    ctx.snapshots.add(id);
    const t0 = Date.now();
    let status = v.snapshot.status;
    while (status !== "ready" && status !== "failed" && Date.now() - t0 < 300_000) {
      await sleep(3000);
      const l = await ctx.api.read("cloud.snapshot.list", { machine: ctx.machine });
      status = (l?.snapshots ?? []).find((s: any) => s.id === id)?.status ?? status;
    }
    log(`use: snapshot ${id} ${status} after ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  } catch (e) {
    log(`use: no snapshot (${String((e as Error).message).slice(0, 300)})`);
  }
}

/** A created preview link's id: the API's link object names it `linkId`. */
export function linkIdOf(body: any): string | null {
  const id = body?.link?.linkId ?? body?.value?.link?.linkId;
  return typeof id === "string" && id ? id : null;
}

/** What the list calls still show of `ids`. A list call that fails is never read as empty: it becomes an `unknown` entry. */
async function listLeftovers(ctx: Ctx, ids: Set<string>): Promise<string[]> {
  const unknown: string[] = [];
  const failed = (what: string) => (e: unknown) => {
    unknown.push(`unknown: ${what} failed (${String((e as Error)?.message ?? e).slice(0, 160)})`);
    return null;
  };
  const machines = await listAllMachines((p) => ctx.api.read("cloud.machine.list", p)).catch(failed("cloud.machine.list"));
  const snaps = await ctx.api.read("cloud.snapshot.list", {}).catch(failed("cloud.snapshot.list"));
  const pv = await ctx.api.raw("GET", "/v1/cloud/previews").catch(failed("GET /v1/cloud/previews"));
  return leftoverReport(ids, machines, snaps, pv, unknown);
}

/** Leftovers of `ids` from the three list answers (null for a call that threw); a malformed or non-2xx answer is unknown, never "none". */
export function leftoverReport(ids: Set<string>, machines: any[] | null, snapsAnswer: any, pv: { status: number; body: any } | null, unknown: string[] = []): string[] {
  const out = [...unknown];
  if (machines !== null && !Array.isArray(machines)) out.push("unknown: cloud.machine.list answered no machine list");
  const snaps = Array.isArray(snapsAnswer?.snapshots) ? snapsAnswer.snapshots : null;
  if (snapsAnswer !== null && !snaps) out.push("unknown: cloud.snapshot.list answered no snapshots list");
  let previews: any[] = [];
  if (pv && (pv.status < 200 || pv.status >= 300)) out.push(`unknown: GET /v1/cloud/previews HTTP ${pv.status}`);
  else if (pv && !Array.isArray(pv.body?.previews)) out.push("unknown: GET /v1/cloud/previews answered no previews list");
  else if (pv) previews = pv.body.previews;
  return [...out, ...leftoversOf(ids, Array.isArray(machines) ? machines : [], snaps ?? [], previews)];
}

type StepsRun = { steps: number; seconds: number; error?: string; ids: Set<string> };

/** One flow's steps on `ctx`, each timed; a wait for a running machine counts only past the create's 30 s answer. */
async function runSteps(label: string, p: PathName, steps: PersonStep[], ctx: Ctx, measured: Measured[], log: (s: string) => void): Promise<StepsRun> {
  const run: StepsRun = { steps: 0, seconds: 0, ids: new Set() };
  const t0 = Date.now();
  try {
    for (const s of steps) {
      if (ctx.machine) run.ids.add(ctx.machine);
      if (s.ops === "waitRunning") {
        const pending = ctx.waited;
        const m: Measured = { flow: label, path: p, step: s.command, kind: s.kind, ops: s.ops, counted: pending, ms: 0, status: pending ? "pass" : "skip", detail: pending ? "the create answered pending" : "running within the create's answer" };
        measured.push(m);
        if (pending) run.steps++;
        log(`${p} ${label}: ${m.status} ${s.command} :: ${m.detail}`);
        continue;
      }
      run.steps++;
      if (s.ops === "none") {
        measured.push({ flow: label, path: p, step: s.command, kind: s.kind, ops: s.ops, counted: true, ms: 0, status: "skip", detail: "counted, not timed (a person's Keychain or GitHub)" });
        continue;
      }
      const s0 = Date.now();
      try {
        const detail = scrub(await OPS[s.ops](ctx), ctx.secrets);
        const ms = Date.now() - s0;
        if (s.ops === "create" || s.ops === "createWait" || s.ops === "redo") ctx.waited = Date.now() - ctx.createdAt > CREATE_ANSWER_MS;
        measured.push({ flow: label, path: p, step: s.command, kind: s.kind, ops: s.ops, counted: true, ms, status: "pass", detail });
        log(`${p} ${label}: pass ${s.command} ${ms} ms :: ${detail}`);
      } catch (e) {
        const detail = scrub(String((e as Error).message ?? e), ctx.secrets).slice(0, 600);
        measured.push({ flow: label, path: p, step: s.command, kind: s.kind, ops: s.ops, counted: true, ms: Date.now() - s0, status: "fail", detail });
        log(`${p} ${label}: FAIL ${s.command} :: ${detail}`);
        throw new Error(`${s.command}: ${detail}`);
      }
      if (ctx.machine) run.ids.add(ctx.machine);
    }
  } catch (e) {
    run.error = String((e as Error).message).slice(0, 300);
  }
  run.seconds = (Date.now() - t0) / 1000;
  return run;
}

/** One path's three flows on one backend; rows plus every step's timing. */
async function runPath(p: PathName, ctx: Ctx, measured: Measured[], log: (s: string) => void): Promise<Row[]> {
  const rows: Row[] = [];
  const flowIds = new Set<string>();
  for (const flow of FLOWS) {
    const steps = PATHS[p][flow];
    if (flow === "redo" && ctx.machine) await use(ctx, log);
    const run = await runSteps(flow, p, steps, ctx, measured, log);
    for (const id of run.ids) flowIds.add(id);
    const row: Row = { flow, path: p, documented_steps: documentedSteps(steps), steps: run.steps, seconds: run.seconds, leftovers: [], source: "staging", ...(run.error ? { error: run.error } : {}) };
    if (flow === "cleanup") row.leftovers = await listLeftovers(ctx, flowIds);
    rows.push(row);
    log(`${p} ${flow}: ${row.steps} steps, ${run.seconds.toFixed(1)} s${row.error ? `, failed: ${row.error}` : ""}`);
    if (row.error) break;
  }
  return rows;
}

/**
 * The faults REDO is measured under (Leo, 2026-11-10: "synthetically just break it fast and repeatedly ... under
 * constraint, under load, under degenerate cases"): each breaks a configured machine with a running agent session,
 * on a machine this run made, before the path's REDO steps bring it back.
 */
export const FAULTS: Record<string, string> = {
  // The agent daemon dies hard: the process holding acpmux's socket, by the pid the socket names.
  "kill the agent daemon": `${'root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }'}; s=/home/cmux/.acpmux/acpmux.sock; pid=$(root ss -xlpn 2>/dev/null | grep -F "$s" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2); [ -n "$pid" ] || { echo "no process holds $s"; exit 1; }; root kill -9 "$pid"; sleep 1; if root kill -0 "$pid" 2>/dev/null; then echo "pid $pid still alive"; exit 1; fi; echo "killed $pid"`,
  // The disk full: one file takes all but ~20 MB of the home volume.
  "fill the disk": `f=/home/cmux/vm-hassle-fill; avail=$(df --output=avail -k /home/cmux | tail -1); fallocate -l $(( (avail - 20000) * 1024 )) "$f" 2>/dev/null || dd if=/dev/zero of="$f" bs=1M count=$(( avail / 1024 - 20 )) 2>/dev/null; left=$(df --output=avail -k /home/cmux | tail -1); [ "$left" -lt 51200 ] || { echo "still $left KiB free"; exit 1; }; echo "$left KiB free"`,
  // The machine config's state corrupted: status, setup state and the applied machine.toml are garbage.
  "corrupt the machine config state": `${'root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }'}; d=/home/cmux/.cmux/machine-config; for f in status.json state.json machine.toml; do printf 'garbage{\\0[' | root tee "$d/$f" >/dev/null; done; if root python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$d/status.json" 2>/dev/null; then echo "status.json still parses"; exit 1; fi; echo corrupted`,
};

/**
 * The shell that stages one apply request and starts the applier detached. One statement per line: a "; " join
 * puts `&;` after the background start, a shell syntax error.
 */
export function applyScript(id: string, stage: string): string {
  return [
    "set -eu", ROOT, "u=cmux", 'h=$(getent passwd "$u" | cut -d: -f6)', 'd="$h/.cmux/machine-config"', `r=${id}`, `s=${stage}`,
    'root mkdir -p "$d/requests" && root chown "$u:$u" "$h/.cmux" "$d" "$d/requests" && root chmod 700 "$d" "$d/requests"',
    'root install -o "$u" -g "$u" -m 700 "$s.apply" "$d/apply"',
    'root install -o "$u" -g "$u" -m 600 "$s.toml" "$d/requests/$r.toml"',
    `printf '{"source":"uploaded"}\\n' > "$s.json" && root install -o "$u" -g "$u" -m 600 "$s.json" "$d/requests/$r.json"`,
    'root rm -f "$s.apply" "$s.toml" "$s.json"',
    'root runuser -u "$u" -- env HOME="$h" setsid nohup python3 -I "$d/apply" >/dev/null 2>&1 </dev/null &',
    "echo started",
  ].join("\n");
}

export function percentile(values: number[], p: number): number {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1))];
}

/** REDO under fault: `rounds` rounds, each every fault at once on its own machine; steps and seconds as p50/max. */
async function faultLeg(p: PathName, rounds: number, newCtx: (name: string) => Ctx, measured: Measured[], log: (s: string) => void): Promise<Row> {
  const runs: StepsRun[] = [];
  const failures: string[] = [];
  for (let round = 0; round < rounds; round++) {
    const done = await Promise.all(Object.entries(FAULTS).map(async ([fault, command], i) => {
      const ctx = newCtx(`${p} fault ${round}${i}`);
      const label = `redo under fault (${fault})`;
      try {
        // Not counted: a configured machine with an agent session, the state REDO has to bring back.
        log(`${p} ${label}: prep ${await OPS.create(ctx)}; ${await OPS.waitConfig(ctx)}; ${await OPS.deliverSecrets(ctx)}; ${await OPS.startSession(ctx)}`);
        // Each fault checks its own effect and exits non-zero when it did not take; such a run measures no recovery.
        const r = await ctx.exec!(command, 120_000);
        if (r.code !== 0) throw new Error(`fault not injected (exit ${r.code}): ${`${r.stdout} ${r.stderr ?? ""}`.trim().slice(-200)}`);
        log(`${p} ${label}: broke it: ${r.stdout.trim().slice(-200)}`);
      } catch (e) {
        failures.push(`${fault}: ${String((e as Error).message).slice(0, 200)}`);
        return null;
      }
      const run = await runSteps(label, p, PATHS[p].redo, ctx, measured, log);
      if (run.error) failures.push(`${fault}: ${run.error}`);
      return run;
    }));
    for (const r of done) if (r && !r.error) runs.push(r);
  }
  const steps = runs.map((r) => r.steps);
  const seconds = runs.map((r) => r.seconds);
  return {
    flow: "redo under fault",
    path: p,
    documented_steps: documentedSteps(PATHS[p].redo),
    steps: runs.length ? percentile(steps, 50) : null,
    steps_max: runs.length ? Math.max(...steps) : undefined,
    seconds: runs.length ? percentile(seconds, 50) : null,
    seconds_max: runs.length ? Math.max(...seconds) : undefined,
    runs: runs.length,
    leftovers: [],
    source: "staging",
    ...(failures.length ? { error: `${failures.length} of ${rounds * Object.keys(FAULTS).length} runs failed: ${failures.join("; ")}` } : {}),
  };
}

/** The steps to clean up after `cmux vm new` was cancelled mid-create: it answered no id, and the create goes on. */
export const INTERRUPTED_CLEANUP: PersonStep[] = [
  { kind: "wait", command: "cmux vm ls (the cancelled create answered no id: find the VM by its name, still being made)", ops: "none" },
  { kind: "command", command: "cmux vm rm NAME --confirm", ops: "delete" },
  { kind: "wait", command: "cmux vm ls (until it is gone)", ops: "verifyGone" },
];

/** CLEANUP after an interrupted SETUP: the create cut off by the client mid-flight, then the person's cleanup. */
async function interruptedLeg(p: PathName, ctx: Ctx, measured: Measured[], log: (s: string) => void): Promise<Row> {
  const row: Row = { flow: "cleanup after interrupted setup", path: p, documented_steps: documentedSteps(INTERRUPTED_CLEANUP), steps: 0, seconds: 0, leftovers: [], source: "staging" };
  // Ctrl-C on `cmux vm new`: the request goes out and the client stops listening 1.5 s in.
  const cut = await http("POST", `${ctx.api.origin}/v1/ops`, { op: "cloud.machine.create", params: { name: ctx.name, size: MACHINE_SIZE }, idempotency_key: keyOf(ctx, "cut") }, { authorization: `Bearer ${ctx.api.bearer}`, ...(ctx.api.team ? { "x-cmux-team": ctx.api.team } : {}) }, 1500).then((r) => `answered ${r.status} before the cut`, (e) => `cut off (${String((e as Error).name ?? e)})`);
  log(`${p} interrupted setup: create ${cut}`);
  const t0 = Date.now();
  // Step 1: find it by name, as `vm ls` would; a create the server never took shows nothing.
  row.steps!++;
  let found: any = null;
  while (Date.now() - t0 < 120_000 && !found) {
    const rows = await listAllMachines((q) => ctx.api.read("cloud.machine.list", q)).catch(() => []);
    found = rows.find((m) => m?.name === ctx.name && m.status !== "deleted") ?? null;
    if (!found) await sleep(2000);
  }
  measured.push({ flow: row.flow, path: p, step: INTERRUPTED_CLEANUP[0].command, kind: "wait", ops: "none", counted: true, ms: Date.now() - t0, status: found ? "pass" : "skip", detail: found ? `${found.id} ${found.status}` : "no machine by that name after 120 s" });
  if (found) {
    ctx.machine = String(found.id);
    ctx.made.add(ctx.machine);
    const rest = await runSteps(row.flow, p, INTERRUPTED_CLEANUP.slice(1), ctx, measured, log);
    row.steps! += rest.steps;
    if (rest.error) row.error = rest.error;
  }
  row.seconds = (Date.now() - t0) / 1000;
  const rows = await listAllMachines((q) => ctx.api.read("cloud.machine.list", q)).catch(() => []);
  const ids = new Set(rows.filter((m) => m?.name === ctx.name).map((m) => String(m.id)));
  for (const id of ids) ctx.made.add(id);
  row.leftovers = await listLeftovers(ctx, ids);
  log(`${p} cleanup after interrupted setup: ${row.steps} steps, ${row.seconds.toFixed(1)} s, leftovers ${row.leftovers.join("; ") || "none"}`);
  return row;
}

/** Delete everything a run made: preview links, snapshots, machines; each by its exact id, leak-safe. */
async function cleanupAll(ctx: Ctx, log: (s: string) => void): Promise<string[]> {
  const failed: string[] = [];
  for (const l of [...ctx.links]) {
    const r = await ctx.api.raw("DELETE", `/v1/cloud/machines/${l.machine}/previews/${l.port}/links/${l.id}`).catch(() => null);
    if (r && (r.status < 300 || r.status === 404)) ctx.links = ctx.links.filter((x) => x !== l);
  }
  for (const id of [...ctx.snapshots]) {
    try {
      await ctx.api.op("cloud.snapshot.delete", { snapshot: id }, `${ctx.tag}-cleanup-snap-${id}`);
      ctx.snapshots.delete(id);
      log(`cleanup: snapshot ${id} deleted`);
    } catch (e) {
      if (/not_found/.test(String((e as Error).message))) ctx.snapshots.delete(id);
      else failed.push(`snapshot ${id}: ${String((e as Error).message).slice(0, 200)}`);
    }
  }
  // A create whose answer was cut off has no id here: find it by this context's name.
  const listed = await listAllMachines((q) => ctx.api.read("cloud.machine.list", q)).catch(() => []);
  for (const m of listed) if (m?.name === ctx.name && m.status !== "deleted") ctx.made.add(String(m.id));
  for (const id of [...ctx.made]) {
    try {
      await ctx.api.deleteMachine(id, `${ctx.tag}-cleanup-${id}`);
      ctx.made.delete(id);
      log(`cleanup: machine ${id} deleted`);
    } catch (e) {
      failed.push(`machine ${id}: ${String((e as Error).message).slice(0, 200)}`);
    }
  }
  return failed;
}

/** --cleanup-tag TAG: what a killed run left, found by name (`vm hassle auto TAG…`) and its snapshots. */
async function cleanupTag(api: Api, tag: string, log: (s: string) => void): Promise<number> {
  if (!/^vh-[a-z0-9]+$/.test(tag)) throw new Error(`--cleanup-tag ${tag}: a vh-… tag`);
  const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
  const mine = rows.filter((m) => typeof m?.name === "string" && m.name.startsWith(`vm hassle auto ${tag}`) && m.status !== "deleted");
  const ids = new Set(mine.map((m) => String(m.id)));
  const snaps: any[] = (await api.read("cloud.snapshot.list", {}).catch(() => null))?.snapshots ?? [];
  let failed = 0;
  for (const s of snaps.filter((s) => s?.name === `vm hassle ${tag}` || ids.has(s?.machine))) {
    await api.op("cloud.snapshot.delete", { snapshot: s.id }, `${tag}-tagclean-${s.id}`).then(() => log(`cleanup-tag: snapshot ${s.id} deleted`), (e) => { failed++; log(`cleanup-tag: snapshot ${s.id} ${String(e.message).slice(0, 200)}`); });
  }
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

function write(outDir: string | null, rows: Row[], measured: Measured[], meta: Record<string, string>): string {
  const md = [
    `## Long-running VM hassle${meta.backend ? ` on \`${meta.backend}\`` : " (documented path)"}`,
    "",
    '> Leo, 2026-11-10: "just as long as long-running VMs are reliable ... are they a hassle to set up? Are they a hassle to redo? Are they a hassle to clean up?"',
    "",
    summaryTable(rows),
    "",
    "steps (code): every step of the path as the CLI's help and action catalog give it, conditional ones included. steps (measured): the ones this run met (a `vm ls` wait only when the create took past its 30 s answer). seconds: the flow's routes on the backend, without a person's think time. leftovers: what the list calls still show of this run's machines after CLEANUP.",
    "",
    "<details><summary>The steps of each path</summary>",
    "",
    pathsMarkdown(),
    "</details>",
    "",
  ].join("\n");
  if (outDir) {
    writeFileSync(path.join(outDir, "vm-hassle.json"), `${JSON.stringify({ meta, rows, steps: measured, documented: PATHS, redo_by_snapshot: REDO_BY_SNAPSHOT }, null, 2)}\n`);
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
    const md = write(outDir, documentedRows(), [], {});
    console.log(md);
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
    log("no agent test account (CMUX_DOGFOOD_STACK_EMAIL / CMUX_DOGFOOD_STACK_PASSWORD): the documented path only");
    console.log(write(outDir, documentedRows(), [], {}));
    return 0;
  }
  const signed = await passwordSignIn(STACK[backend.stack], email, password);
  secrets.push(signed.access, signed.refresh);
  api.bearer = signed.access;
  await api.op("user.ensure", {}, `vh-ensure-${randomUUID().slice(0, 8)}`);
  const cleanupTagArg = argValue("--cleanup-tag", argv);
  if (cleanupTagArg !== undefined) return cleanupTag(api, cleanupTagArg, log);

  const tag = argValue("--tag", argv) ?? `vh-${Date.now().toString(36)}`;
  const which = argValue("--path", argv) ?? "both";
  const paths: PathName[] = which === "both" ? ["before", "after"] : which === "before" || which === "after" ? [which] : [];
  if (!paths.length) throw new Error(`--path ${which}: before, after or both`);
  const health = await http("GET", `${backend.api}/v1/health`, undefined, {}).catch(() => null);
  const meta = { backend: backend.name, api: backend.api, tag, commit: String(health?.body?.commit ?? health?.body?.version ?? "?"), team: team ?? "(personal)" };
  log(`vm hassle on ${backend.name} (${backend.api}), tag ${tag}, paths ${paths.join(",")}`);
  const contexts: Ctx[] = [];
  const rows: Row[] = [];
  const measured: Measured[] = [];
  let cleaned = false;
  const cleanup = async () => {
    if (cleaned) return;
    cleaned = true;
    const failed: string[] = [];
    for (const c of contexts) failed.push(...(await cleanupAll(c, log)));
    if (failed.length) log(`cleanup FAILED: ${failed.join("; ")} (run --cleanup-tag ${tag})`);
    return failed;
  };
  const onSignal = (signal: string) => {
    void cleanup().finally(() => {
      write(outDir, rows, measured, meta);
      process.exit(signal === "SIGINT" ? 130 : 143);
    });
  };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  let failedCleanup: string[] | undefined = [];
  try {
    const newCtx = (suffix: string): Ctx => {
      const ctx: Ctx = { api, tag, secrets, made: new Set(), snapshots: new Set(), links: [], machine: null, name: `vm hassle auto ${tag} ${suffix}`, createdAt: 0, exec: null, waited: false };
      contexts.push(ctx);
      return ctx;
    };
    const rounds = Math.max(0, Math.min(5, Number(argValue("--fault-rounds", argv) ?? 1)));
    for (const p of paths) {
      rows.push(...(await runPath(p, newCtx(p), measured, log)));
      if (rounds) rows.push(await faultLeg(p, rounds, newCtx, measured, log));
      rows.push(await interruptedLeg(p, newCtx(`${p} cut`), measured, log));
    }
  } finally {
    process.off("SIGTERM", onSignal);
    process.off("SIGINT", onSignal);
    failedCleanup = await cleanup();
  }
  const md = write(outDir, rows, measured, meta);
  console.log(md);
  const failed = rows.filter((r) => r.error).length;
  return failed || failedCleanup?.length ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
