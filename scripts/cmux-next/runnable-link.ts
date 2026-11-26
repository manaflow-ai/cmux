#!/usr/bin/env bun
// Runnable links on staging (cmuxterm-hq#23807, RFD 0168): a link that opens a working copy of a live
// project. Measures click-to-usable for the link against today's way (a fresh machine, clone, install,
// start), on real staging machines.
//
// Setup: one parent machine; clone a real project (PROJECT_REPO at PROJECT_REF), install its deps, start
// its service, start an agent session on acpmux whose launch credential is a canary value.
// Mint: POST {platform}/v1/runnable-links (cmux-platform, RUNNABLE_LINKS on), or, where that answers 404,
// the same thing from its parts (cloud.snapshot.create): the link's version is that snapshot.
// Open, --runs times: resolve the link (no compute), fork it (POST .../fork, or cloud.snapshot.restore),
// wait running, first exec, scrub (end every process that holds a model credential in its environment:
// the copy never runs on the sender's login; acpmux keeps the session and relaunches it on the opener's
// credential at the next prompt), then usable = the service answers 200 + the smoke test passes + acpmux
// lists the session. Each phase is timed. The canary is looked for in every process environment on the
// copy before and after the scrub.
// Baseline, --baseline times: a fresh machine, clone, install, start, smoke: the same "usable".
// Negative checks (link API only): a revoked link and an expired link refuse to fork.
// Prints one JSON verdict (and writes --out).
//
//   bun scripts/cmux-next/runnable-link.ts [--backend staging] [--runs N] [--baseline N] [--out FILE] [--keep]
//
// Credentials: CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD (the staging agent test account).

import { writeFileSync } from "node:fs";
import {
  Api,
  CHAT_START_SIZE,
  STACK,
  clientPlatformOrigin,
  directExec,
  http,
  launchCredentialStartProgram,
  listAllMachines,
  passwordSignIn,
  resolveBackend,
  scrub,
  sleep,
  waitMachine,
  type Exec,
} from "./cloud-journey.ts";
import { firstExec, mintInstallToken, p95 } from "./cloud-fork-placement.ts";

const arg = (name: string, fallback?: string) => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
};

export const PROJECT_REPO = "https://github.com/expressjs/express.git";
export const PROJECT_REF = "4.21.2";
export const PROJECT_DIR = "/home/cmux/project";
export const SERVICE_PORT = 3000;
export const SESSION = "runnable-link-demo";

/** Clone, install, start the service detached. Prints head=, then service= once it answers. */
export function projectSetupCommand(): string {
  return [
    "set -e",
    `rm -rf ${PROJECT_DIR}`,
    `git clone -q --depth 1 --branch ${PROJECT_REF} ${PROJECT_REPO} ${PROJECT_DIR}`,
    `cd ${PROJECT_DIR}`,
    "NODE_ENV=development npm install --include=dev --no-audit --no-fund --loglevel=error >/tmp/rl-install.log 2>&1",
    `PORT=${SERVICE_PORT} setsid node examples/hello-world >/tmp/rl-service.log 2>&1 < /dev/null &`,
    `for i in $(seq 1 100); do curl -sf -o /dev/null http://127.0.0.1:${SERVICE_PORT}/ && break; sleep 0.1; done`,
    `echo "head=$(git rev-parse HEAD)"`,
    `echo "service=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${SERVICE_PORT}/)"`,
  ].join("\n");
}

/** The smoke runner, one line each: test/app.js through mocha's API, resolved from the project. */
export const SMOKE_RUNNER = [
  "const M = require(require.resolve('mocha', { paths: [process.cwd()] }))",
  "const m = new M({ reporter: 'dot' })",
  "m.addFile('test/app.js')",
  "m.run((f) => process.exit(f ? 1 : 0))",
];

/** Usable: the service answers 200, the project's smoke test passes, acpmux lists the session (when one is expected). */
export function usableCommand(session: string | null): string {
  return [
    `s=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:${SERVICE_PORT}/ || true); echo "service=$s"`,
    // Mocha through its API, not its CLI: the CLI's old yargs loads as an ES module under Node 26 and throws.
    `printf '%s\\n' ${SMOKE_RUNNER.map((l) => `"${l}"`).join(" ")} >/tmp/rl-smoke.cjs`,
    `cd ${PROJECT_DIR} && NODE_ENV=test node /tmp/rl-smoke.cjs >/tmp/rl-smoke.log 2>&1 && echo smoke=1 || { echo smoke=0; echo "smoke_err=$(grep -m2 -E 'Error|failing' /tmp/rl-smoke.log | tr '\\n' ' ' | cut -c1-300)"; echo "node=$(node -v 2>&1)"; }`,
    `echo "head=$(git -C ${PROJECT_DIR} rev-parse HEAD 2>/dev/null)"`,
    session ? `acpmux ls 2>/dev/null | grep -q '${session}' && echo session=1 || echo session=0` : "echo session=skip",
  ].join("\n");
}

/** How many process environments on this machine hold the canary (read as the machine's user). */
export function canaryCountCommand(canary: string): string {
  return `n=0; for d in /proc/[0-9]*; do [ -O "$d" ] || continue; grep -qaF '${canary}' "$d/environ" 2>/dev/null && n=$((n+1)); done; echo "canary=$n"`;
}

/** The scrub: end every process of this user holding a model credential in its environment. */
export const SCRUB_COMMAND =
  `n=0; for d in /proc/[0-9]*; do [ -O "$d" ] || continue; p=\${d#/proc/}; [ "$p" = "$$" ] && continue; ` +
  `tr '\\0' '\\n' < "$d/environ" 2>/dev/null | grep -qE '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|OPENAI_API_KEY|CODEX_API_KEY)=' || continue; ` +
  `kill -TERM "$p" 2>/dev/null && n=$((n+1)); done; sleep 0.3; echo "scrubbed=$n"`;

export function facts(stdout: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of stdout.split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

export const usable = (f: Record<string, string>, head: string) =>
  f.service === "200" && f.smoke === "1" && f.head === head && (f.session === "1" || f.session === "skip");

export type OpenRow = {
  run: number;
  quota_wait_ms?: number;
  via: "link" | "snapshot";
  copy: string | null;
  resolve_ms: number | null;
  fork_call_ms: number | null;
  running_ms: number | null;
  first_exec_ms: number | null;
  scrub_ms: number | null;
  usable_ms: number | null;
  click_to_usable_ms: number | null;
  canary_before_scrub: number | null;
  canary_after_scrub: number | null;
  facts: Record<string, string> | null;
  error: string | null;
};
export type BaselineRow = { run: number; quota_wait_ms?: number; machine: string | null; create_ms: number | null; setup_ms: number | null; usable_ms: number | null; total_ms: number | null; facts: Record<string, string> | null; error: string | null };

const median = (xs: number[]) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor((s.length - 1) / 2)];
};
const stat = (xs: (number | null)[]) => {
  const v = xs.filter((x): x is number => typeof x === "number");
  return { median: median(v), p95: p95(v), all: v };
};

export function verdict(opens: OpenRow[], baseline: BaselineRow[], meta: Record<string, unknown>) {
  const ok = opens.filter((r) => r.click_to_usable_ms !== null && r.canary_after_scrub === 0);
  const click = stat(opens.map((r) => r.click_to_usable_ms));
  const base = stat(baseline.map((r) => r.total_ms));
  return {
    kind: "runnable-link",
    ...meta,
    opens: opens.length,
    opens_usable_and_clean: ok.length,
    click_to_usable_ms: click,
    baseline_ms: base,
    speedup_p50: click.median && base.median ? Number((base.median / click.median).toFixed(2)) : null,
    phases_ms: Object.fromEntries((["resolve_ms", "fork_call_ms", "running_ms", "first_exec_ms", "scrub_ms", "usable_ms"] as const).map((k) => [k, stat(opens.map((r) => r[k]))])),
    pass: opens.length > 0 && ok.length === opens.length,
    rows: opens,
    baseline_rows: baseline,
  };
}

/** A staging machine create can run past the 60 s op default (run 45600635121: three timeouts at the parent). */
const CREATE_TIMEOUT_MS = 240_000;

/** Staging's test team sits near its machine cap; a create that hits it waits for room instead of
 * failing the row (25 min, or ROOM_WAIT_MS). Returns the value and the time spent waiting, which the caller leaves out of its phase timing. */
export async function withRoom<T>(fn: () => Promise<T>, budgetMs = Number(process.env.ROOM_WAIT_MS ?? 1_500_000)): Promise<[T, number]> {
  // Returns the time spent waiting for room only: a full team (cloud.quota.vm_limit) waits and is left out of
  // the timing. A call cut off at the client timeout is asked again, at most twice, under the same idempotency
  // key, so it cannot make a second machine (runs 45570177493 and 45571955695 stopped there); that time counts.
  const t0 = Date.now();
  let roomAt = t0;
  let timeouts = 0;
  for (;;) {
    try {
      return [await fn(), roomAt - t0];
    } catch (e) {
      const m = String((e as Error).message);
      if (m.includes("cloud.quota.vm_limit") && Date.now() - t0 <= budgetMs) {
        await sleep(15_000);
        roomAt = Date.now();
        continue;
      }
      if (m.includes("timed out") && ++timeouts <= 2) {
        await sleep(2_000);
        continue;
      }
      throw e;
    }
  }
}

/**
 * Machines this script made that no one deletes otherwise: this run's (a create cut off at the client timeout can
 * still make its machine, which the run never learns the id of: runs 45570177493, 45571955695 and 45573615938), and
 * any earlier run's older than STRAY_AGE_MS. Every machine here is named "runnable link rl-<tag> ...".
 */
// A row's creation time in ms: machines carry a number, snapshots may carry an ISO string. Unknown reads as new.
function createdMs(r: any): number {
  const v = r?.created_at ?? r?.createdAt;
  if (typeof v === "number") return v;
  const t = typeof v === "string" ? Date.parse(v) : NaN;
  return Number.isFinite(t) ? t : Number.POSITIVE_INFINITY;
}

// A cleanup line that only says NOT deleted hid why (run 45713223869 left a failed parent and a stray); carry the reason.
const whyNot = (e: unknown) => String((e as Error)?.message ?? e).replace(/\s+/g, " ").slice(0, 160);

// Snapshots this script left behind (a run killed before its finally) count against the team's snapshot quota; run
// 45703015793 had both the link mint and the plain snapshot refused with cloud.quota.exceeded. Sweep them like machines.
const snapshotRows = (list: any): any[] => (Array.isArray(list) ? list : list?.snapshots ?? list?.items ?? []);

// Returns the ids it deleted. A delete that returns has not yet freed its slot: run 45756094330 swept both stray link
// snapshots before the mint, and the list read after the refused mint still showed them live (5/5, quota exceeded).
async function sweepSnapshots(api: any, tag: string, keepId: string | null, cleanup: string[]): Promise<string[]> {
  const list = await api.read("cloud.snapshot.list", {}).catch(() => null);
  if (!list) return (cleanup.push("snapshot sweep: list failed"), []);
  const gone: string[] = [];
  for (const id of strays(snapshotRows(list), tag, Date.now(), new Set(keepId ? [keepId] : []))) {
    await api.op("cloud.snapshot.delete", { snapshot: id }, `${tag}-snap-del-stray-${id}`).then(() => (gone.push(id), cleanup.push(`stray snapshot ${id} deleted`)), (e) => cleanup.push(`stray snapshot ${id} NOT deleted: ${whyNot(e)}`));
  }
  return gone;
}

// Ids of `ids` the list still holds live; the mint waits on this reaching empty so the swept slots are free.
export function stillLive(rows: any[], ids: string[]): string[] {
  const want = new Set(ids);
  return rows.filter((r) => want.has(String(r?.id ?? "")) && r?.status !== "deleted" && r?.status !== "deleting").map((r) => String(r.id));
}

async function settleSweep(api: any, ids: string[], boundMs: number): Promise<{ ms: number; left: string[] }> {
  const t0 = Date.now();
  let left = ids;
  while (left.length && Date.now() - t0 < boundMs) {
    const list = await api.read("cloud.snapshot.list", {}).catch(() => null);
    if (list) left = stillLive(snapshotRows(list), ids);
    if (left.length) await sleep(5_000);
  }
  return { ms: Date.now() - t0, left };
}

/** Who fills the team's snapshot slots (the provider limit refuses both the link and the plain snapshot, run
 *  45705522020): counts by a name shape (digits and ids folded to #), so the leaking script can be named. */
export function snapshotCensus(rows: any[], now: number): { total: number; live: number; oldest_h: number | null; by_shape: Record<string, number> } {
  const live = rows.filter((r) => r?.status !== "deleted" && r?.status !== "deleting");
  const by: Record<string, number> = {};
  let oldest = Number.POSITIVE_INFINITY;
  for (const r of live) {
    const shape = String(r?.name ?? "(unnamed)").replace(/[0-9a-z]*[0-9][0-9a-z]*/gi, "#").slice(0, 40);
    by[shape] = (by[shape] ?? 0) + 1;
    oldest = Math.min(oldest, createdMs(r));
  }
  const top = Object.fromEntries(Object.entries(by).sort((a, b) => b[1] - a[1]).slice(0, 8));
  return { total: rows.length, live: live.length, oldest_h: Number.isFinite(oldest) ? Math.round((now - oldest) / 360_000) / 10 : null, by_shape: top };
}

// The run tag a row's name carries: "runnable link rl-<tag> ..." (machines, plain snapshots) or the link API's own
// snapshot name "link <user> rl-<tag>-mint..." (its clientKey). The sweep matched only the first, so every link snapshot a
// run left (no revoke before it died) stayed: 6 of the team's 9 provider snapshot slots in run 45716117127's census.
export function runTag(name: unknown): string | null {
  if (typeof name !== "string") return null;
  const m = /^runnable link (rl-[0-9a-z]+)(?: |$)/.exec(name) ?? /^link \S+ (rl-[0-9a-z]+)-mint(?:-expiring)?$/.exec(name);
  return m ? m[1] : null;
}

// No run outlives its job (runnable-link.yml timeout-minutes: 75), so a row of this script older than that belongs to a dead
// run. The old two-hour bound kept two link snapshots of runs 40 minutes gone, and with three other snapshots that filled
// staging's five slots (run 45734544111: cloud.quota.exceeded at mint).
export const STRAY_AGE_MS = 80 * 60_000;

export function strays(rows: any[], tag: string, now: number, deleted: Set<string>): string[] {
  return rows
    .filter((r) => runTag(r?.name) !== null && r.status !== "deleted" && r.status !== "deleting")
    // A failed row of this script is never restorable yet still holds a quota slot (run 45760655846: before the mint the
    // list held a 47-minute-old failed link snapshot of an earlier run, and two failed foreign ones), so it goes at any age.
    .filter((r) => runTag(r.name) === tag || r.status === "failed" || now - createdMs(r) >= STRAY_AGE_MS)
    .map((r) => String(r.id ?? r.machine_id ?? ""))
    .filter((id) => id && !deleted.has(id));
}

async function waitUsable(exec: Exec, session: string | null, head: string, budgetMs: number): Promise<Record<string, string>> {
  const t0 = Date.now();
  let f: Record<string, string> = {};
  while (Date.now() - t0 < budgetMs) {
    f = facts((await exec(usableCommand(session), 90_000).catch((e) => ({ stdout: `error=${(e as Error).message}` }))).stdout);
    if (usable(f, head)) return f;
    await sleep(500);
  }
  throw new Error(`not usable in ${budgetMs} ms: ${JSON.stringify(f)}`);
}

async function main(): Promise<number> {
  const backend = resolveBackend(arg("--backend", "staging")!);
  const runs = Math.max(1, Math.min(10, Number(arg("--runs", "10"))));
  const baselineRuns = Math.max(0, Math.min(10, Number(arg("--baseline", "3"))));
  const keep = process.argv.includes("--keep");
  const team = arg("--team") || undefined;
  const secrets: string[] = [];
  const api = new Api(backend.api, team);
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD (the staging agent test account)");
  secrets.push(password);
  // Each step names itself, so a bare "The operation timed out." says where (run 45570177493 did not).
  let stage = "sign-in";
  const s = await passwordSignIn(STACK[backend.stack], email, password);
  secrets.push(s.access, s.refresh);
  api.bearer = s.access;
  const say = (v: unknown) => console.log(scrub(typeof v === "string" ? v : JSON.stringify(v), secrets));
  stage = "client-config";
  const platform = clientPlatformOrigin((await api.raw("GET", "/v1/client-config", undefined, 30_000)).body);
  const tag = `rl-${Date.now().toString(36)}`;
  stage = "user.ensure";
  const user = await api.op("user.ensure", {}, `${tag}-ensure`);
  stage = "install token";
  const install = await mintInstallToken(api, backend.api, String(user?.id ?? user?.user?.id ?? ""), tag, team);
  secrets.push(install.token);
  let bearer = install.token;
  const renew = async () => { bearer = await install.renew(); secrets.push(bearer); };
  const ph = () => ({ authorization: `Bearer ${bearer}`, ...(team ? { "x-cmux-team": team } : {}) });
  const journey = { secrets };
  const canary = `sk-ant-canary-${tag}-${Math.random().toString(36).slice(2, 12)}`;
  const cleanup: string[] = [];
  const machines: string[] = [];
  const opens: OpenRow[] = [];
  const baseline: BaselineRow[] = [];
  const negative: Record<string, unknown> = {};
  const meta: Record<string, unknown> = { backend: backend.name, project: `${PROJECT_REPO}@${PROJECT_REF}`, tag };
  let snapshot: string | null = null;
  let link: any = null;
  let linkRevoked = false; // a link not revoked keeps its snapshot past expiry (cmux-platform deletes it on revoke only)
  let parent: string | null = null;
  try {
    // Parent: a real project, its service running, an agent session holding the canary as its launch credential.
    stage = "parent create";
    const t0 = Date.now();
    const [created] = await withRoom(() => api.op("cloud.machine.create", { name: `runnable link ${tag} parent`, size: CHAT_START_SIZE }, `${tag}-parent`, {}, CREATE_TIMEOUT_MS));
    parent = String(created?.machine?.id ?? created?.machine ?? created?.id);
    machines.push(parent);
    await waitMachine(api, parent, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
    const pexec = directExec(api, parent, journey);
    await firstExec(pexec, 120_000);
    meta.parent_ready_ms = Date.now() - t0;
    stage = "parent setup";
    const s0 = Date.now();
    const setup = await pexec(projectSetupCommand(), 280_000);
    if (setup.code !== 0) throw new Error(`project setup: exit ${setup.code} ${setup.stderr.slice(-400)}`);
    meta.parent_setup_ms = Date.now() - s0;
    const head = facts(setup.stdout).head;
    meta.head = head;
    const started = await pexec(launchCredentialStartProgram(SESSION, "claude", "ANTHROPIC_API_KEY", canary), 120_000);
    const sessionUp = started.stdout.includes("@@session ");
    meta.session_started = sessionUp ? true : scrub(started.stdout.slice(-300), [...secrets, canary]);
    meta.parent_canary = facts((await pexec(canaryCountCommand(canary), 30_000)).stdout).canary;
    const session = sessionUp ? SESSION : null;

    // Mint.
    stage = "mint";
    if (!keep) {
      // What holds the slots just before the mint, row by row (run 45758368273 swept nothing here yet the mint was
      // refused at 5/5 with two link snapshots live afterwards: this says whether they were there before it).
      const pre = await api.read("cloud.snapshot.list", {}).catch(() => null);
      if (pre) meta.pre_mint_snapshots = snapshotRows(pre).map((r) => `${String(r?.id ?? "").slice(0, 10)} ${String(r?.name ?? "").replace(/user_\w+/, "user").slice(0, 40)} ${r?.status} ${Number.isFinite(createdMs(r)) ? Math.round((Date.now() - createdMs(r)) / 60_000) + "m" : "?"}`);
      const swept = await sweepSnapshots(api, tag, null, cleanup);
      if (swept.length) {
        const settled = await settleSweep(api, swept, 180_000);
        meta.sweep_settle = { swept: swept.length, ms: settled.ms, still_live: settled.left.length };
      }
    }
    const m0 = Date.now();
    const mint = () => http("POST", `${platform}/v1/runnable-links`, {
      machine: parent, clientKey: `${tag}-mint`, ttlSeconds: 3600, note: "hq#23807 experiment",
      manifest: { repo: PROJECT_REPO, ref: PROJECT_REF, head, sessions: session ? [session] : [], smoke: "mocha test/app.js", service: { port: SERVICE_PORT, path: "/" } },
    }, ph(), 180_000, true);
    let minted = await mint();
    // A new machine is private; the platform asks its creator to share it with the team first (link.machine_private,
    // run 45605879435). Do what a person would: share it, then mint again. The share is part of the mint's time.
    if (minted.status === 403 && minted.body?.code === "link.machine_private") {
      const shared = await http("PUT", `${platform}/v1/machines/${parent}/visibility`, { visibility: "team" }, ph(), 60_000, true);
      meta.shared_with_team = shared.status;
      if (shared.status === 200) minted = await mint();
    }
    if (minted.status === 200 || minted.status === 201) {
      link = minted.body;
      snapshot = link.snapshotId;
      meta.via = "link";
      meta.disclosure = link.disclosure;
      // "cloud" (a vm_ through CloudDO, platform#2105) or the team-machine path.
      meta.link_source = link.source ?? "team";
    } else {
      meta.via = "snapshot";
      // The code tells a flag that is off (link.not_found before auth) from a refusal of this machine.
      meta.link_api = `HTTP ${minted.status} ${String(minted.body?.code ?? minted.body?.error ?? "").slice(0, 80)}`.trim();
      // Which quota: the details name the resource and its used/limit (machines vs snapshots).
      const d = minted.body?.details ?? minted.body?.error?.details;
      if (d && typeof d === "object") meta.link_api_details = JSON.stringify({ resource: d.resource, used: d.used, limit: d.limit, busy: d.busy }).slice(0, 200);
      const census = await api.read("cloud.snapshot.list", {}).catch(() => null);
      if (census) meta.snapshot_census = snapshotCensus(Array.isArray(census) ? census : census?.snapshots ?? census?.items ?? [], Date.now());
      const snap = await api.op("cloud.snapshot.create", { machine: parent, name: `runnable link ${tag}` }, `${tag}-snap`);
      snapshot = String(snap?.snapshot?.id ?? snap?.snapshot ?? snap?.id);
    }
    // Ready: listed ready (snapshot path) — a link's fork waits for it itself, but the mint is timed to ready either way.
    for (;;) {
      const list = await api.read("cloud.snapshot.list", {}).catch(() => null);
      const rows: any[] = Array.isArray(list) ? list : list?.snapshots ?? list?.items ?? [];
      const row = rows.find((r) => r?.id === snapshot);
      if (!row || row?.status === "ready" || row?.state === "ready") break;
      if (row?.status === "failed") throw new Error(`snapshot failed: ${String(row?.error?.code ?? "")} ${String(row?.error?.message ?? "").slice(0, 120)}`.trim());
      if (Date.now() - m0 > 360_000) throw new Error("snapshot not ready in 6 minutes");
      await sleep(500);
    }
    meta.mint_ms = Date.now() - m0;
    say({ phase: "minted", via: meta.via, mint_ms: meta.mint_ms, link: link?.id ?? null });

    // Opens.
    for (let run = 1; run <= runs; run++) {
      const r: OpenRow = { run, via: link ? "link" : "snapshot", copy: null, resolve_ms: null, fork_call_ms: null, running_ms: null, first_exec_ms: null, scrub_ms: null, usable_ms: null, click_to_usable_ms: null, canary_before_scrub: null, canary_after_scrub: null, facts: null, error: null };
      const c0 = Date.now();
      try {
        await renew();
        if (link) {
          const g = await http("GET", `${platform}/v1/runnable-links/${link.id}`, undefined, ph(), 15_000);
          if (g.status !== 200) throw new Error(`resolve: HTTP ${g.status}`);
        }
        r.resolve_ms = Date.now() - c0;
        let quotaWait = 0;
        let f0 = Date.now();
        if (link) {
          const [f, waited] = await withRoom(async () => {
            const f = await http("POST", `${platform}/v1/runnable-links/${link.id}/fork`, { clientKey: `${tag}-open-${run}` }, ph(), 180_000, true);
            if (f.status !== 200 && f.status !== 201) throw new Error(`fork: HTTP ${f.status} ${JSON.stringify(f.body).slice(0, 200)}`);
            return f;
          });
          quotaWait = waited;
          r.copy = String(f.body?.machine?.id);
        } else {
          const [a, waited] = await withRoom(() => api.op("cloud.snapshot.restore", { snapshot, name: `runnable link ${tag} open ${run}` }, `${tag}-open-${run}`));
          quotaWait = waited;
          r.copy = String(a?.machine?.id ?? a?.machine ?? a?.id);
        }
        machines.push(r.copy);
        f0 += quotaWait;
        r.quota_wait_ms = quotaWait;
        r.fork_call_ms = Date.now() - f0;
        await waitMachine(api, r.copy, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
        r.running_ms = Date.now() - f0;
        const exec = directExec(api, r.copy, journey);
        r.first_exec_ms = await firstExec(exec, 180_000);
        r.canary_before_scrub = Number(facts((await exec(canaryCountCommand(canary), 30_000)).stdout).canary);
        const k0 = Date.now();
        await exec(SCRUB_COMMAND, 30_000);
        r.scrub_ms = Date.now() - k0;
        r.canary_after_scrub = Number(facts((await exec(canaryCountCommand(canary), 30_000)).stdout).canary);
        const u0 = Date.now();
        r.facts = await waitUsable(exec, session, head, 120_000);
        r.usable_ms = Date.now() - u0;
        r.click_to_usable_ms = Date.now() - c0 - (r.quota_wait_ms ?? 0);
      } catch (e) {
        r.error = scrub(String((e as Error).message), [...secrets, canary]).slice(0, 400);
      } finally {
        if (r.copy && !keep) await api.deleteMachine(r.copy, `${tag}-del-open-${run}`).then(() => cleanup.push(`copy ${run} deleted`), (e) => cleanup.push(`copy ${run} NOT deleted (${r.copy}): ${whyNot(e)}`));
      }
      opens.push(r);
      say({ phase: "open", run, click_to_usable_ms: r.click_to_usable_ms, canary_after_scrub: r.canary_after_scrub, error: r.error });
    }

    // Negative checks (link API only).
    if (link) {
      await renew();
      const short = await http("POST", `${platform}/v1/runnable-links`, { machine: parent, clientKey: `${tag}-mint-expiring`, ttlSeconds: 5 }, ph(), 180_000, true);
      if (short.status === 200 || short.status === 201) {
        await sleep(7_000);
        const e = await http("POST", `${platform}/v1/runnable-links/${short.body.id}/fork`, { clientKey: `${tag}-expired` }, ph(), 60_000, true);
        negative.expired = { status: e.status, code: e.body?.code ?? e.body?._tag ?? null, refused: e.status === 410 };
        await http("DELETE", `${platform}/v1/runnable-links/${short.body.id}`, undefined, ph(), 60_000, true);
      } else negative.expired = { mint_status: short.status };
      const d = await http("DELETE", `${platform}/v1/runnable-links/${link.id}`, undefined, ph(), 60_000, true);
      const v = await http("POST", `${platform}/v1/runnable-links/${link.id}/fork`, { clientKey: `${tag}-revoked` }, ph(), 60_000, true);
      linkRevoked = d.status >= 200 && d.status < 300;
      negative.revoked = { delete_status: d.status, status: v.status, code: v.body?.code ?? v.body?._tag ?? null, refused: v.status === 410 };
      const noAuth = await http("GET", `${platform}/v1/runnable-links/${link.id}`, undefined, {}, 15_000);
      negative.unauthenticated = { status: noAuth.status, refused: noAuth.status === 401 || noAuth.status === 404 };
      snapshot = null; // the revoke deleted it
    }

    // Baseline: a fresh machine, clone, install, start, smoke.
    for (let run = 1; run <= baselineRuns; run++) {
      const b: BaselineRow = { run, machine: null, create_ms: null, setup_ms: null, usable_ms: null, total_ms: null, facts: null, error: null };
      let b0 = Date.now();
      try {
        await renew();
        const [c, waited] = await withRoom(() => api.op("cloud.machine.create", { name: `runnable link ${tag} baseline ${run}`, size: CHAT_START_SIZE }, `${tag}-base-${run}`, {}, CREATE_TIMEOUT_MS));
        b.quota_wait_ms = waited;
        b0 += waited;
        b.machine = String(c?.machine?.id ?? c?.machine ?? c?.id);
        machines.push(b.machine);
        await waitMachine(api, b.machine, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
        const exec = directExec(api, b.machine, journey);
        await firstExec(exec, 120_000);
        b.create_ms = Date.now() - b0;
        const s1 = Date.now();
        const st = await exec(projectSetupCommand(), 280_000);
        if (st.code !== 0) throw new Error(`setup: exit ${st.code} ${st.stderr.slice(-300)}`);
        b.setup_ms = Date.now() - s1;
        const u1 = Date.now();
        b.facts = await waitUsable(exec, null, head, 120_000);
        b.usable_ms = Date.now() - u1;
        b.total_ms = Date.now() - b0;
      } catch (e) {
        b.error = scrub(String((e as Error).message), secrets).slice(0, 400);
      } finally {
        if (b.machine && !keep) await api.deleteMachine(b.machine, `${tag}-del-base-${run}`).then(() => cleanup.push(`baseline ${run} deleted`), (e) => cleanup.push(`baseline ${run} NOT deleted (${b.machine}): ${whyNot(e)}`));
      }
      baseline.push(b);
      say({ phase: "baseline", run, total_ms: b.total_ms, error: b.error });
    }
  } catch (e) {
    meta.error = scrub(`${stage}: ${String((e as Error).message)}`, [...secrets, canary]).slice(0, 600);
  } finally {
    if (link?.id && !linkRevoked && !keep) {
      const d = await http("DELETE", `${platform}/v1/runnable-links/${link.id}`, undefined, ph(), 60_000, true).catch((e: unknown) => ({ status: 0, body: whyNot(e) }));
      cleanup.push(d.status >= 200 && d.status < 300 ? "link revoked" : `link NOT revoked (${link.id}): HTTP ${d.status}`);
    }
    if (snapshot && !keep) await api.op("cloud.snapshot.delete", { snapshot }, `${tag}-snap-del`).then(() => cleanup.push("snapshot deleted"), (e) => cleanup.push(`snapshot NOT deleted (${snapshot}): ${whyNot(e)}`));
    if (parent && !keep) await api.deleteMachine(parent, `${tag}-del-parent`).then(() => cleanup.push("parent deleted"), (e) => cleanup.push(`parent NOT deleted (${parent}): ${whyNot(e)}`));
    if (!keep) {
      const done = new Set(parent ? [parent] : []);
      const rows = await listAllMachines((q) => api.read("cloud.machine.list", q)).catch(() => null);
      if (!rows) cleanup.push("stray sweep: list failed");
      for (const id of rows ? strays(rows, tag, Date.now(), done) : []) {
        await api.deleteMachine(id, `${tag}-del-stray-${id}`).then(() => cleanup.push(`stray ${id} deleted`), (e) => cleanup.push(`stray ${id} NOT deleted: ${whyNot(e)}`));
      }
      await sweepSnapshots(api, tag, null, cleanup);
    }
  }
  const out = { ...verdict(opens, baseline, meta), negative, cleanup, kept: keep ? machines : [] };
  const text = scrub(JSON.stringify(out), [...secrets, canary]);
  const file = arg("--out");
  if (file) writeFileSync(file, text);
  console.log(text);
  return out.pass ? 0 : 1;
}

if (import.meta.main) process.exit(await main());
