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
//       [--team TEAM] [--runs N] [--out FILE] [--risky]
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
  /** --risky only: the step's exit on the parent and whether the copy kept what it dropped. */
  risky?: { step_exit: number; parent_lost_work: boolean; copy_kept_work: boolean } | null;
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
    fork_call_ms: { median: median(nums("fork_call_ms")), all: nums("fork_call_ms") },
    fork_to_first_exec_ms: { median: median(nums("fork_to_first_exec_ms")), all: nums("fork_to_first_exec_ms") },
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
async function mintInstallToken(api: Api, apiBase: string, userId: string, tag: string, team?: string): Promise<{ id: string; token: string }> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const inst = await api.op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: `cloud journey jr-${tag.slice(3)}`, device_name: "cloud fork placement", platform: "linux" }, `${tag}-install`);
  const user = String(inst?.user ?? userId);
  const ch = await http("POST", `${apiBase}/v1/auth/challenge`, { user, install: inst.id, ...(team ? { team } : {}) }, {});
  if (ch.status !== 200) throw new Error(`challenge: HTTP ${ch.status}`);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`)));
  const tok = await http("POST", `${apiBase}/v1/auth/token`, { user, install: inst.id, nonce: ch.body.nonce, signature: Buffer.from(sig).toString("base64url") }, {}, 25_000);
  if (tok.status !== 200 || typeof tok.body?.access_token !== "string") throw new Error(`token: HTTP ${tok.status}`);
  return { id: String(inst.id), token: tok.body.access_token };
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
  const platformHeaders = () => ({ authorization: `Bearer ${install.token}`, ...(team ? { "x-cmux-team": team } : {}) });
  const journey = { secrets };
  const rows: RunRow[] = [];
  for (let run = 1; run <= runs; run++) {
    const row: RunRow = { run, parent: null, child: null, parent_ready_ms: null, fork_call_ms: null, fork_status: null, fork_to_first_exec_ms: null, parity: null, child_cost: null, agent: "not tried", error: null, cleanup: [], ...(risky ? { risky: null } : {}) };
    try {
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
      const f0 = Date.now();
      const clientKey = risky ? `risky-${tag}-${run}` : `${tag}-fork-${run}`;
      const forked = await http("POST", `${platform}/v1/machines/${encodeURIComponent(row.parent)}/fork`, { clientKey }, platformHeaders(), 180_000, true);
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
      const read = await http("GET", `${platform}/v1/machines/${encodeURIComponent(row.child)}`, undefined, platformHeaders(), 15_000);
      row.child_cost = read.status === 200 ? { route: "GET {platform}/v1/machines/{id} cost", cost: read.body?.cost ?? null } : { route: "GET {platform}/v1/machines/{id}", status: read.status };
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
  await api.op("install.revoke", { install: install.id }, `${tag}-install-revoke`).catch((e) => say(`install ${install.id} not revoked: ${String((e as Error).message).slice(0, 200)}`));
  const v = verdict(rows, { backend: backend.name, platform, at: new Date().toISOString(), mode: risky ? "risky" : "placement" });
  const line = scrub(JSON.stringify(v), secrets);
  const out = arg("--out");
  if (out) writeFileSync(out, `${line}\n`);
  console.log(line);
  return v.pass ? 0 : 1;
}

if (import.meta.main) process.exit(await main());
