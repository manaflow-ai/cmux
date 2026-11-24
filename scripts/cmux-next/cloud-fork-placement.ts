#!/usr/bin/env bun
// Fork placement on staging (RFD 0168): what a new session placed on a fork of its parent's Cloud
// machine gets, and what it costs in time.
//
// Per run: create a parent machine, write a marker file, commit a git repo and start a counter
// process on it; fork it with cmux-platform's POST /v1/machines/{id}/fork (the call cmux-cloud-api's
// `machine.fork` makes); time the fork call and fork-to-first-exec on the copy; check parity on
// the copy (the marker's sha256, `git rev-parse HEAD`, the counter's pid alive and still counting);
// read the copy's cost as the platform's TeamMachine answers it (`cost`, the route a person's app
// reads; the internal usage route needs the internal bearer this job does not hold); delete both.
// Prints one JSON verdict line at the end (and writes it to --out when given).
//
//   bun scripts/cmux-next/cloud-fork-placement.ts [--backend staging] [--sign-in password|oidc]
//       [--team TEAM] [--runs N] [--duress N] [--out FILE] [--risky]
//
// --risky (RFD 0163 row 25, acpmux fork_risky.rs): "Fork first" before a risky step. The parent's
// checkout gets uncommitted work; the fork is taken with a `risky-` clientKey, as the daemon takes it
// before it lets the step run; then the step runs on the parent (`git reset --hard && git clean
// -fdx`), and the run checks the parent lost the work and the copy, the checkpoint, kept it.
// `fork_call_ms` is then the time the person's Fork first holds the step.
//
// Credentials: CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD (the staging agent test
// account), or --sign-in oidc in a GitHub Actions job the API trusts.

import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import {
  Api,
  CHAT_START_SIZE,
  STACK,
  clientPlatformOrigin,
  directExec,
  http,
  oidcSignIn,
  passwordSignIn,
  resolveBackend,
  scrub,
  sleep,
  waitMachine,
  type Exec,
} from "./cloud-journey.ts";

const arg = (name: string, fallback?: string) => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
};

const MARKER = "/tmp/cmux-fork-marker";
const REPO = "/tmp/cmux-fork-repo";
const COUNTER = "/tmp/cmux-fork-counter";
const WORK = `${REPO}/uncommitted-work.txt`;

/** --risky: uncommitted work in the checkout, which the risky step drops. Prints its sha256. */
export function dirtyCommand(nonce: string): string {
  return [`printf '%s' 'work-${nonce}' > ${WORK}`, `echo "work=$(sha256sum ${WORK} | cut -d' ' -f1)"`].join("\n");
}

/** The risky step the person allows after Fork first: drops every uncommitted change. */
export const RISKY_STEP = `cd ${REPO} && git reset -q --hard && git clean -qfdx`;

/** The work file's sha256 now, or empty when it is gone. */
export function workCommand(): string {
  return `echo "work=$(sha256sum ${WORK} 2>/dev/null | cut -d' ' -f1)"`;
}

/** cmux-platform's answer for a machine it does not know (yet). */
export function notFound(status: number, body: any): boolean {
  return status === 404 && (body?.code === "machine.not_found" || body?._tag === "MachineNotFound");
}

/** Whether the checkpoint held: the parent lost the work and the copy kept it. */
export function checkpointKept(before: string | undefined, parent: string | undefined, copy: string | undefined) {
  return { parent_lost_work: !!before && !parent, copy_kept_work: !!before && copy === before };
}

export type Parity = { marker: boolean; head: boolean; process_alive: boolean; process_counting: boolean };
export type RunRow = {
  run: number;
  parent: string | null;
  child: string | null;
  parent_ready_ms: number | null;
  fork_call_ms: number | null;
  fork_status: number | null;
  fork_to_first_exec_ms: number | null;
  parity: Parity | null;
  child_cost: unknown;
  agent: string;
  error: string | null;
  cleanup: string[];
  /** How many times the fork answered 404 machine.not_found before it answered for good. */
  fork_not_found_retries?: number;
  /** --risky only: the step's exit on the parent and whether the copy kept what it dropped. */
  risky?: { step_exit: number; parent_lost_work: boolean; copy_kept_work: boolean } | null;
  /** --split: the fork's steps done one at a time on the same parent (see splitPhases). */
  split?: SplitRow | null;
  /** The copy's create trace (GET /v1/machines/{id}?include=trace): where its restore's time went. */
  create_trace?: unknown;
};

/** --duress N: N forks of one parent at once; each fork's call and fork-to-first-exec, then every copy deleted. */
export type DuressRow = { forks: number; parent: string | null; fork_call_ms: number[]; fork_to_first_exec_ms: number[]; errors: string[]; cleanup: string[] };

export const p95 = (xs: number[]) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.ceil(s.length * 0.95) - 1)];
};

/**
 * The platform's fork is capture (cloud.snapshot.create until the snapshot is ready), then create
 * (cloud.snapshot.restore), then size, stepped by its operation loop (cmux-platform PlatformOperations.ts).
 * --split times each step from here: snapshot_call_ms (the op's answer), snapshot_ready_ms (listed ready),
 * restore_call_ms, restore_running_ms (machine running with a host), boot_to_exec_ms (first command),
 * acpmux_ready_ms (acpmux answers). The fork call minus their sum is what the operation loop adds.
 */
export type SplitRow = {
  snapshot_call_ms: number | null;
  snapshot_ready_ms: number | null;
  restore_call_ms: number | null;
  restore_running_ms: number | null;
  boot_to_exec_ms: number | null;
  acpmux_ready_ms: number | null;
  restore_timings: unknown;
  error: string | null;
};

/** The setup command: marker, one-commit repo, a detached counter. Prints marker sha, HEAD, pid. */
export function setupCommand(nonce: string): string {
  return [
    "set -e",
    `printf '%s' '${nonce}' > ${MARKER}`,
    `rm -rf ${REPO} && mkdir -p ${REPO} && cd ${REPO}`,
    "git init -q . && git -c user.email=fork@cmux.test -c user.name=fork commit -q --allow-empty -m fork-placement",
    `setsid sh -c 'i=0; while :; do i=$((i+1)); echo $i > ${COUNTER}; sleep 1; done' >/dev/null 2>&1 < /dev/null & echo $! > ${COUNTER}.pid`,
    "sleep 2",
    `echo "marker=$(sha256sum ${MARKER} | cut -d' ' -f1)"`,
    `echo "head=$(git -C ${REPO} rev-parse HEAD)"`,
    `echo "pid=$(cat ${COUNTER}.pid)"`,
  ].join("\n");
}

/** The parity read: the same three facts and whether the counter moves. */
export function parityCommand(): string {
  return [
    `echo "marker=$(sha256sum ${MARKER} 2>/dev/null | cut -d' ' -f1)"`,
    `echo "head=$(git -C ${REPO} rev-parse HEAD 2>/dev/null)"`,
    `p=$(cat ${COUNTER}.pid 2>/dev/null); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo alive=1; else echo alive=0; fi`,
    `a=$(cat ${COUNTER} 2>/dev/null); sleep 3; b=$(cat ${COUNTER} 2>/dev/null); echo "count=$a:$b"`,
  ].join("\n");
}

export function facts(stdout: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of stdout.split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

export function parity(parent: Record<string, string>, child: Record<string, string>): Parity {
  const [a, b] = (child.count ?? "").split(":").map(Number);
  return {
    marker: !!parent.marker && parent.marker === child.marker,
    head: !!parent.head && parent.head === child.head,
    process_alive: child.alive === "1",
    process_counting: Number.isFinite(a) && Number.isFinite(b) && b > a,
  };
}

const median = (xs: number[]) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor((s.length - 1) / 2)];
};

export function verdict(rows: RunRow[], meta: Record<string, unknown>) {
  const kept = (r: RunRow) => r.risky === undefined || (!!r.risky && r.risky.step_exit === 0 && r.risky.parent_lost_work && r.risky.copy_kept_work);
  const ok = rows.filter((r) => r.parity && Object.values(r.parity).every(Boolean) && kept(r));
  const nums = (k: "fork_call_ms" | "fork_to_first_exec_ms") => rows.map((r) => r[k]).filter((v): v is number => typeof v === "number");
  return {
    kind: "cloud-fork-placement",
    ...meta,
    runs: rows.length,
    parity_ok: ok.length,
    fork_call_ms: { median: median(nums("fork_call_ms")), p95: p95(nums("fork_call_ms")), all: nums("fork_call_ms") },
    fork_to_first_exec_ms: { median: median(nums("fork_to_first_exec_ms")), p95: p95(nums("fork_to_first_exec_ms")), all: nums("fork_to_first_exec_ms") },
    pass: rows.length > 0 && ok.length === rows.length,
    rows,
  };
}

async function firstExec(exec: Exec, budgetMs: number): Promise<number> {
  const t0 = Date.now();
  let last = "";
  while (Date.now() - t0 < budgetMs) {
    try {
      const r = await exec("true", 15_000);
      if (r.code === 0) return Date.now() - t0;
      last = `exit ${r.code}`;
    } catch (e) {
      last = String((e as Error).message);
    }
    await sleep(500);
  }
  throw new Error(`no exec on the copy in ${budgetMs} ms: ${last}`);
}

/** A cmux access token for a fresh install (P-256 key, challenge, signed nonce): what the app sends the platform. */
async function mintInstallToken(api: Api, apiBase: string, userId: string, tag: string, team?: string): Promise<{ id: string; token: string; renew: () => Promise<string> }> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const inst = await api.op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: `cloud journey jr-${tag.slice(3)}`, device_name: "cloud fork placement", platform: "linux" }, `${tag}-install`);
  const user = String(inst?.user ?? userId);
  // The token outlives a few minutes only: a 10-run drill plus duress answered 401 machine.unauthorized from about
  // minute 12 (run 45473883603). renew() signs a fresh challenge with the same install's key, as the app does.
  const renew = async (): Promise<string> => {
    const ch = await http("POST", `${apiBase}/v1/auth/challenge`, { user, install: inst.id, ...(team ? { team } : {}) }, {});
    if (ch.status !== 200) throw new Error(`challenge: HTTP ${ch.status}`);
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`)));
    const tok = await http("POST", `${apiBase}/v1/auth/token`, { user, install: inst.id, nonce: ch.body.nonce, signature: Buffer.from(sig).toString("base64url") }, {}, 25_000);
    if (tok.status !== 200 || typeof tok.body?.access_token !== "string") throw new Error(`token: HTTP ${tok.status}`);
    return tok.body.access_token;
  };
  return { id: String(inst.id), token: await renew(), renew };
}

async function splitPhases(api: Api, parent: string, tag: string, run: number, journey: { secrets: string[] }, cleanup: string[]): Promise<SplitRow> {
  const r: SplitRow = { snapshot_call_ms: null, snapshot_ready_ms: null, restore_call_ms: null, restore_running_ms: null, boot_to_exec_ms: null, acpmux_ready_ms: null, restore_timings: null, error: null };
  let snapshot: string | null = null;
  let copy: string | null = null;
  try {
    const s0 = Date.now();
    const snap = await api.op("cloud.snapshot.create", { machine: parent, name: `cloud fork placement ${tag} split ${run}` }, `${tag}-split-snap-${run}`);
    r.snapshot_call_ms = Date.now() - s0;
    const id = snap?.snapshot?.id ?? snap?.snapshot ?? snap?.id;
    if (typeof id !== "string") throw new Error(`snapshot.create answered no id`);
    snapshot = id;
    for (;;) {
      const list = await api.read("cloud.snapshot.list", {}).catch(() => null);
      const rows: any[] = Array.isArray(list) ? list : list?.snapshots ?? list?.items ?? [];
      const row = rows.find((x) => x?.id === id);
      if (row?.status === "failed") throw new Error("snapshot failed");
      if (row?.status === "ready") break;
      if (Date.now() - s0 > 360_000) throw new Error("snapshot not ready in 6 minutes");
      await sleep(500);
    }
    r.snapshot_ready_ms = Date.now() - s0;
    const c0 = Date.now();
    const answer = await api.op("cloud.snapshot.restore", { snapshot: id, name: `cloud fork placement ${tag} split ${run}` }, `${tag}-split-restore-${run}`);
    r.restore_call_ms = Date.now() - c0;
    r.restore_timings = answer?.timings ?? answer?.machine?.timings ?? null;
    copy = String(answer?.machine?.id ?? answer?.machine ?? answer?.id);
    await waitMachine(api, copy, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
    r.restore_running_ms = Date.now() - c0;
    const exec = directExec(api, copy, journey);
    const e0 = Date.now();
    await firstExec(exec, 180_000);
    r.boot_to_exec_ms = Date.now() - e0;
    const a0 = Date.now();
    for (;;) {
      const a = await exec("command -v acpmux >/dev/null && acpmux ls >/dev/null 2>&1 && echo up || echo down", 30_000).catch(() => ({ stdout: "" }));
      if (a.stdout.includes("up")) break;
      if (Date.now() - a0 > 120_000) throw new Error("acpmux did not answer in 120 s");
      await sleep(500);
    }
    r.acpmux_ready_ms = Date.now() - a0;
  } catch (e) {
    r.error = scrub(String((e as Error).message), journey.secrets).slice(0, 300);
  } finally {
    if (copy) await api.deleteMachine(copy, `${tag}-split-delete-${run}`).then(() => cleanup.push("split copy deleted"), () => cleanup.push(`split copy NOT deleted (${copy})`));
    if (snapshot) {
      for (let attempt = 1; ; attempt++) {
        const err = await api.op("cloud.snapshot.delete", { snapshot }, `${tag}-split-snap-delete-${run}-${attempt}`).then(() => null, (e: unknown) => String((e as Error)?.message ?? e));
        if (err === null || /not_found/.test(err)) { cleanup.push("split snapshot deleted"); break; }
        if (attempt >= 12) { cleanup.push(`split snapshot NOT deleted (${snapshot})`); break; }
        await sleep(10_000);
      }
    }
  }
  return r;
}

async function main(): Promise<number> {
  const backend = resolveBackend(arg("--backend", "staging")!);
  const runs = Math.max(1, Math.min(10, Number(arg("--runs", "1"))));
  const team = arg("--team") || undefined;
  const risky = process.argv.includes("--risky");
  const secrets: string[] = [];
  const api = new Api(backend.api, team);
  if (arg("--sign-in", "password") === "oidc") api.bearer = (await oidcSignIn(backend.api, process.env, secrets)).token;
  else {
    const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
    const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
    if (!email || !password) throw new Error("set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD (the staging agent test account)");
    secrets.push(password);
    const s = await passwordSignIn(STACK[backend.stack], email, password);
    secrets.push(s.access, s.refresh);
    api.bearer = s.access;
  }
  const say = (v: unknown) => console.log(scrub(typeof v === "string" ? v : JSON.stringify(v), secrets));
  const platform = clientPlatformOrigin((await api.raw("GET", "/v1/client-config", undefined, 30_000)).body);
  const tag = `fp-${Date.now().toString(36)}`;
  // cmux-platform's machine routes take a cmux access token with a team claim, not the Stack session (all
  // five fork calls answered 401 machine.unauthorized with it, run 45412063929): an install of this run's own,
  // as the app mints it (cloud-journey.ts "install token"), revoked at the end.
  const user = await api.op("user.ensure", {}, `${tag}-ensure`);
  const install = await mintInstallToken(api, backend.api, String(user?.id ?? user?.user?.id ?? ""), tag, team);
  secrets.push(install.token);
  let bearer = install.token;
  const renewToken = async () => {
    bearer = await install.renew();
    secrets.push(bearer);
  };
  const platformHeaders = () => ({ authorization: `Bearer ${bearer}`, ...(team ? { "x-cmux-team": team } : {}) });
  const journey = { secrets };
  const rows: RunRow[] = [];
  for (let run = 1; run <= runs; run++) {
    const row: RunRow = { run, parent: null, child: null, parent_ready_ms: null, fork_call_ms: null, fork_status: null, fork_to_first_exec_ms: null, parity: null, child_cost: null, agent: "not tried", error: null, cleanup: [], ...(risky ? { risky: null } : {}) };
    try {
      if (run > 1) await renewToken();
      const t0 = Date.now();
      const created = await api.op("cloud.machine.create", { name: `cloud fork placement ${tag} ${run}`, size: CHAT_START_SIZE }, `${tag}-parent-${run}`);
      row.parent = String(created?.machine?.id ?? created?.machine ?? created?.id);
      await waitMachine(api, row.parent, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
      const parentExec = directExec(api, row.parent, journey);
      await firstExec(parentExec, 120_000);
      row.parent_ready_ms = Date.now() - t0;
      const nonce = `${tag}-${run}-${Math.random().toString(36).slice(2)}`;
      const setup = await parentExec(setupCommand(nonce), 60_000);
      if (setup.code !== 0) throw new Error(`setup on the parent: exit ${setup.code} ${setup.stderr.slice(0, 300)}`);
      const before = facts(setup.stdout);
      const expect = createHash("sha256").update(nonce).digest("hex");
      if (before.marker !== expect) throw new Error(`the parent's marker is not the nonce's sha256 (${before.marker})`);
      let work: string | undefined;
      if (risky) {
        const dirty = await parentExec(dirtyCommand(nonce), 30_000);
        work = facts(dirty.stdout).work;
        if (!work) throw new Error(`no uncommitted work on the parent: exit ${dirty.code}`);
      }
      const clientKey = risky ? `risky-${tag}-${run}` : `${tag}-fork-${run}`;
      // cmux-platform answered 404 machine.not_found for a parent the API had just reported running, on runs
      // 1, 3 and 5 of run 45456177673: it had not learned the machine yet. Ask again with the same clientKey
      // (idempotent) for up to 60 s; fork_call_ms times the call that answered, fork_not_found_retries counts.
      let forked: Awaited<ReturnType<typeof http>>;
      let f0 = Date.now();
      const deadline = Date.now() + 60_000;
      row.fork_not_found_retries = 0;
      for (;;) {
        f0 = Date.now();
        forked = await http("POST", `${platform}/v1/machines/${encodeURIComponent(row.parent)}/fork`, { clientKey }, platformHeaders(), 180_000, true);
        if (!notFound(forked.status, forked.body) || Date.now() > deadline) break;
        row.fork_not_found_retries++;
        await new Promise((r) => setTimeout(r, 3_000));
      }
      row.fork_call_ms = Date.now() - f0;
      row.fork_status = forked.status;
      if (forked.status !== 200 || typeof forked.body?.id !== "string") throw new Error(`fork: HTTP ${forked.status} ${JSON.stringify(forked.body).slice(0, 300)}`);
      row.child = forked.body.id as string;
      const childExec = directExec(api, row.child, journey);
      if (risky) {
        // The fork answered: the person's allow goes through now, and the step runs on the parent.
        const step = await parentExec(RISKY_STEP, 60_000);
        const left = facts((await parentExec(workCommand(), 30_000)).stdout).work;
        row.risky = { step_exit: step.code, ...checkpointKept(work, left, undefined) };
      }
      row.fork_to_first_exec_ms = row.fork_call_ms + (await firstExec(childExec, 180_000));
      const after = await childExec(parityCommand(), 60_000);
      row.parity = parity(before, facts(after.stdout));
      if (row.risky) {
        const kept = facts((await childExec(workCommand(), 30_000)).stdout).work;
        row.risky = { ...row.risky, copy_kept_work: checkpointKept(work, undefined, kept).copy_kept_work };
      }
      // An agent on the copy: the cheap check is that the guest's acpmux answers there.
      const agent = await childExec("command -v acpmux >/dev/null && acpmux ls >/dev/null 2>&1 && echo up || echo down", 30_000).catch((e) => ({ code: 1, stdout: "", stderr: String((e as Error).message) }));
      row.agent = agent.stdout.includes("up") ? "acpmux answers on the copy" : `acpmux did not answer: ${(agent.stderr || agent.stdout).slice(0, 200)}`;
      const read = await http("GET", `${platform}/v1/machines/${encodeURIComponent(row.child)}?include=trace`, undefined, platformHeaders(), 15_000);
      row.child_cost = read.status === 200 ? { route: "GET {platform}/v1/machines/{id} cost", cost: read.body?.cost ?? null } : { route: "GET {platform}/v1/machines/{id}", status: read.status };
      row.create_trace = read.status === 200 ? read.body?.createTrace ?? read.body?.trace ?? null : null;
      if (process.argv.includes("--split")) row.split = await splitPhases(api, row.parent, tag, run, journey, row.cleanup);
    } catch (e) {
      row.error = scrub(String((e as Error).message), secrets);
    } finally {
      for (const [which, id] of [["child", row.child], ["parent", row.parent]] as const) {
        if (!id) continue;
        try {
          await api.deleteMachine(id, `${tag}-delete-${which}-${run}`);
          row.cleanup.push(`${which} deleted`);
        } catch (e) {
          const d = await http("DELETE", `${platform}/v1/machines/${encodeURIComponent(id)}`, undefined, platformHeaders(), 60_000, true).catch(() => null);
          row.cleanup.push(d && d.status < 300 ? `${which} deleted on the platform` : `${which} NOT deleted (${id}): ${String((e as Error).message).slice(0, 120)}`);
        }
      }
    }
    say({ row });
    rows.push(row);
  }
  const duressN = Math.max(0, Math.min(8, Number(arg("--duress", "0"))));
  let duress: DuressRow | null = null;
  if (duressN > 0) {
    const d: DuressRow = { forks: duressN, parent: null, fork_call_ms: [], fork_to_first_exec_ms: [], errors: [], cleanup: [] };
    const copies: string[] = [];
    try {
      const created = await api.op("cloud.machine.create", { name: `cloud fork placement ${tag} duress`, size: CHAT_START_SIZE }, `${tag}-duress-parent`);
      d.parent = String(created?.machine?.id ?? created?.machine ?? created?.id);
      await waitMachine(api, d.parent, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
      await firstExec(directExec(api, d.parent, journey), 120_000);
      await renewToken();
      await Promise.all(
        Array.from({ length: duressN }, async (_, i) => {
          try {
            const f0 = Date.now();
            const forked = await http("POST", `${platform}/v1/machines/${encodeURIComponent(d.parent!)}/fork`, { clientKey: `${tag}-duress-fork-${i}` }, platformHeaders(), 180_000, true);
            const call = Date.now() - f0;
            if (forked.status !== 200 || typeof forked.body?.id !== "string") throw new Error(`fork ${i}: HTTP ${forked.status} ${JSON.stringify(forked.body).slice(0, 200)}`);
            copies.push(forked.body.id as string);
            d.fork_call_ms.push(call);
            d.fork_to_first_exec_ms.push(call + (await firstExec(directExec(api, forked.body.id as string, journey), 180_000)));
          } catch (e) {
            d.errors.push(scrub(String((e as Error).message), secrets).slice(0, 300));
          }
        }),
      );
    } catch (e) {
      d.errors.push(scrub(String((e as Error).message), secrets).slice(0, 300));
    } finally {
      for (const [i, id] of [...copies, d.parent].entries()) {
        if (!id) continue;
        await api.deleteMachine(id, `${tag}-duress-delete-${i}`).then(
          () => d.cleanup.push(`${id} deleted`),
          (e: unknown) => d.cleanup.push(`${id} NOT deleted: ${String((e as Error)?.message ?? e).slice(0, 120)}`),
        );
      }
    }
    say({ duress: d });
    duress = d;
  }
  await api.op("install.revoke", { install: install.id }, `${tag}-install-revoke`).catch((e) => say(`install ${install.id} not revoked: ${String((e as Error).message).slice(0, 200)}`));
  const v = { ...verdict(rows, { backend: backend.name, platform, at: new Date().toISOString(), mode: risky ? "risky" : "placement" }), ...(duress ? { duress: { ...duress, fork_call_p50: median(duress.fork_call_ms), fork_call_p95: p95(duress.fork_call_ms), first_exec_p50: median(duress.fork_to_first_exec_ms), first_exec_p95: p95(duress.fork_to_first_exec_ms) } } : {}) };
  const line = scrub(JSON.stringify(v), secrets);
  const out = arg("--out");
  if (out) writeFileSync(out, `${line}\n`);
  console.log(line);
  return v.pass ? 0 : 1;
}

if (import.meta.main) process.exit(await main());
