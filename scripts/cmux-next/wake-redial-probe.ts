#!/usr/bin/env bun
/**
 * Measurement only (no product code): does a `cmux carrier serve` connection wake a Cloud machine that cmux paused for
 * idleness, and how long does a redial take to reach a stream, for the published build (before) and PR #50108's (after).
 *
 *   bun scripts/cmux-next/wake-redial-probe.ts --before PATH --after PATH --out DIR [--idle N] [--wake N] [--quiet N] [--wait-min M]
 *
 * Reads CMUX_DOGFOOD_STACK_EMAIL / _PASSWORD (the staging agent test account). Every machine it makes is deleted in finally.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, writeFileSync, chmodSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import net from "node:net";
import path from "node:path";
import { Api, STACK, passwordSignIn, resolveBackend, machineStopFields } from "./cloud-journey.ts";

const argv = process.argv.slice(2);
const arg = (n: string, d?: string) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const BEFORE = arg("--before")!, AFTER = arg("--after")!, OUT = arg("--out", "out")!;
const N_IDLE = Number(arg("--idle", "5")), WAIT_MIN = Number(arg("--wait-min", "40"));
const N_QUIET = Number(arg("--quiet", "2"));
mkdirSync(OUT, { recursive: true });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const email = process.env.CMUX_DOGFOOD_STACK_EMAIL!, password = process.env.CMUX_DOGFOOD_STACK_PASSWORD!;
const backend = resolveBackend(arg("--backend", "staging")!);
const api = new Api(backend.api);
const secrets: string[] = [password];
const scrub = (s: string) => secrets.reduce((t, x) => (x ? t.split(x).join("<secret>") : t), s);
const log = (...a: unknown[]) => console.log(new Date().toISOString(), scrub(a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ")));
const results: any = { backend: backend.name, trials: [], machines: [], notes: [] };
const save = () => writeFileSync(path.join(OUT, "wake-probe.json"), JSON.stringify(results, null, 2));

let token = "";
let signedAt = 0;
/** One sign-in reused for 5 min (the run before signed in per poll and hit Stack's 429); a 429 backs off up to ~10 min. */
async function fresh(): Promise<string> {
  if (token && Date.now() - signedAt < 5 * 60_000) return token;
  for (let attempt = 0, wait = 5_000; ; attempt++, wait = Math.min(wait * 2, 120_000)) {
    try {
      const s = await passwordSignIn(STACK[backend.stack], email, password);
      secrets.push(s.access, s.refresh);
      api.bearer = token = s.access;
      signedAt = Date.now();
      return token;
    } catch (e) {
      if (!String(e).includes("429") || attempt >= 8) throw e;
      log("sign-in 429, retry in", wait, "ms"); await sleep(wait);
    }
  }
}
const get = async (id: string) => { await fresh(); return api.read("cloud.machine.get", { machine: id }); };

const created: string[] = [];
async function create(name: string): Promise<string> {
  await fresh();
  const sizes = [{ cpu: 2, memory_mb: 4096, disk_mb: 16384 }, { cpu: 4, memory_mb: 16384, disk_mb: 65536 }];
  let err: unknown;
  for (const size of sizes) {
    try {
      const v = await api.op("cloud.machine.create", { name, size, seed: "none" }, `${name}-${Date.now()}`);
      created.push(v.machine.id);
      return v.machine.id;
    } catch (e) { err = e; log("create failed", String(e)); }
  }
  throw err;
}
async function waitFor(id: string, want: (m: any) => boolean, budgetMs: number): Promise<any> {
  const t0 = Date.now();
  let last: any;
  while (Date.now() - t0 < budgetMs) {
    try { last = await get(id); if (want(last)) return last; } catch (e) { log("poll", id, String(e)); }
    await sleep(2000);
  }
  throw new Error(`${id}: not in the wanted state in ${budgetMs} ms; last ${JSON.stringify(machineStopFields(last))}`);
}

type Serve = { child: ChildProcess; sock: string; lines: { t: number; line: string }[]; dir: string };
async function startServe(bin: string, id: string): Promise<Serve> {
  const dir = mkdtempSync(path.join(tmpdir(), "wk-"));
  chmodSync(dir, 0o700);
  const sock = path.join(dir, "s.sock");
  const tokFile = path.join(dir, "tok");
  await fresh();
  writeFileSync(tokFile, token, { mode: 0o600 });
  const child = spawn(bin, ["carrier", "serve", "--machine", id, "--socket", sock, "--cloud-api", backend.api, "--cloud-token-file", tokFile, "--deadline-ms", "240000"], {
    stdio: ["pipe", "ignore", "pipe"], env: { ...process.env, XDG_STATE_HOME: path.join(dir, "state"), CMUX_STATE_DIR: path.join(dir, "state") },
  });
  const lines: Serve["lines"] = [];
  let buf = "";
  child.stderr!.on("data", (d) => { buf += d; let i; while ((i = buf.indexOf("\n")) >= 0) { lines.push({ t: Date.now(), line: scrub(buf.slice(0, i)) }); buf = buf.slice(i + 1); } });
  const t0 = Date.now();
  while (!lines.some((l) => l.line.includes('"socket"')) && Date.now() - t0 < 20000) {
    if (child.exitCode !== null) throw new Error(`serve exited ${child.exitCode}: ${lines.map((l) => l.line).join(" | ")}`);
    await sleep(50);
  }
  if (!lines.some((l) => l.line.includes('"socket"'))) throw new Error(`serve not ready: ${lines.map((l) => l.line).join(" | ")}`);
  return { child, sock, lines, dir };
}
function stopServe(s: Serve) { try { s.child.stdin!.end(); } catch {} setTimeout(() => { if (s.child.exitCode === null) s.child.kill("SIGTERM"); }, 2000); }
function dial(sock: string): Promise<net.Socket> {
  return new Promise((res, rej) => { const c = net.connect(sock); c.on("connect", () => res(c)); c.on("error", rej); c.on("data", () => {}); });
}

/** One connect, no session held: ms to the serve's per-connection line, and the machine's status every poll until `watchMs`. */
async function trial(label: string, bin: string, id: string, quiet: boolean, watchMs: number, stopAt?: (m: any) => boolean) {
  const s = await startServe(bin, id);
  const before = await get(id);
  const t0 = Date.now();
  const readyLines0 = s.lines.length;
  let conn: net.Socket | null = null;
  let closedMs: number | null = null;
  try {
    conn = await dial(quiet ? `${s.sock}.quiet` : s.sock);
    conn.on("close", () => { closedMs = Date.now() - t0; });
  } catch (e) { log(label, "connect error", String(e)); }
  const statuses: { ms: number; status: string; reason?: unknown }[] = [];
  let runningMs: number | null = null;
  while (Date.now() - t0 < watchMs) {
    try {
      const m = await get(id);
      const f: any = machineStopFields(m);
      if (!statuses.length || statuses[statuses.length - 1].status !== m.status) statuses.push({ ms: Date.now() - t0, status: m.status, reason: f.pause_reason ?? f.paused_by });
      if (m.status === "running" && runningMs === null) runningMs = Date.now() - t0;
      if (stopAt && stopAt(m) && s.lines.length > readyLines0) break;
    } catch (e) { log(label, "poll", String(e)); }
    await sleep(1000);
  }
  const lines = s.lines.slice(readyLines0).map((l) => ({ ms: l.t - t0, line: l.line }));
  const rec = { label, bin: path.basename(path.dirname(bin)) || bin, quiet, machine: id, before: machineStopFields(before), statuses, running_ms: runningMs, conn_closed_ms: closedMs, serve_lines_after_connect: lines };
  results.trials.push(rec); save();
  log("TRIAL", rec);
  try { conn?.destroy(); } catch {}
  stopServe(s);
  return rec;
}

async function main() {
  // 1. machines, an idle policy on each, then wait for cmux's own pause.
  const ids: string[] = [];
  for (let i = 0; i < N_IDLE + N_QUIET; i++) {
    try { ids.push(await create(`wake probe ${Date.now().toString(36)} ${i}`)); } catch (e) { results.notes.push(`create ${i}: ${e}`); break; }
  }
  const personId = await create(`wake probe person ${Date.now().toString(36)}`).catch((e) => { results.notes.push(`create person: ${e}`); return null; });
  results.machines = [...ids, ...(personId ? [personId] : [])]; save();
  log("machines", results.machines);
  for (const id of results.machines) await waitFor(id, (m) => m.status === "running" && Boolean(m.host), 300_000).then((m) => log("running", id, machineStopFields(m)));
  for (const id of ids) {
    await fresh();
    for (const sec of [60, 900]) {
      try { const r = await api.op("cloud.machine.idle_policy.set", { machine: id, idle_seconds: sec }, `idle-${id}-${sec}`); results.notes.push(`idle_policy ${id} ${sec}s ok ${JSON.stringify(r).slice(0, 200)}`); break; }
      catch (e) { results.notes.push(`idle_policy ${id} ${sec}s: ${e}`); log("idle_policy", id, sec, String(e)); }
    }
  }
  // person pause (the path the CLI offers) for the contrast
  if (personId) {
    await fresh();
    await api.op("cloud.machine.pause", { machine: personId }, `pp-${personId}`);
    const m = await waitFor(personId, (x) => x.status === "paused", 180_000);
    results.person_pause = machineStopFields(m); log("person paused", results.person_pause);
  }
  // 2. wait for idle pauses
  const idleDone: string[] = [];
  const t0 = Date.now();
  while (Date.now() - t0 < WAIT_MIN * 60_000 && idleDone.length < ids.length) {
    for (const id of ids) {
      if (idleDone.includes(id)) continue;
      const m = await get(id).catch(() => null);
      if (m?.status === "paused") { idleDone.push(id); results.notes.push(`${id} paused after ${Math.round((Date.now() - t0) / 1000)} s: ${JSON.stringify(machineStopFields(m))}`); log("idle paused", id, machineStopFields(m)); }
    }
    save(); await sleep(15_000);
  }
  // 3. the wake trials (before binary, main socket) on idle-paused machines, then quiet trials (after binary) on the rest
  const wakeIds = idleDone.slice(0, N_IDLE), quietIds = idleDone.slice(N_IDLE);
  for (const [i, id] of wakeIds.entries()) await trial(`wake-before-${i}`, BEFORE, id, false, 240_000, (m) => m.status === "running");
  for (const [i, id] of quietIds.entries()) await trial(`quiet-after-${i}`, AFTER, id, true, 60_000);
  if (personId) await trial("wake-before-person", BEFORE, personId, false, 60_000);
  // 4. redial-to-stream on running machines, cold serve each time, before main socket vs after quiet socket
  const run = wakeIds[0] ?? ids[0];
  if (run) {
    await fresh();
    const m = await waitFor(run, (x) => x.status === "running" && Boolean(x.host), 240_000).catch(async () => { await api.op("cloud.machine.start", { machine: run }, `st-${run}-${Date.now()}`).catch(() => {}); return waitFor(run, (x) => x.status === "running", 240_000); });
    for (let i = 0; i < 5; i++) {
      await trial(`stream-before-${i}`, BEFORE, run, false, 60_000, () => true);
      await trial(`stream-after-quiet-${i}`, AFTER, run, true, 60_000, () => true);
    }
  }
  save();
}

// --delete-only ID,ID: delete machines an earlier run of this probe made and failed to delete, then stop.
const deleteOnly = (arg("--delete-only", "") ?? "").split(/[\s,]+/).filter(Boolean);
if (deleteOnly.length) created.push(...deleteOnly);
try { if (!deleteOnly.length) await main(); }
catch (e) { results.notes.push(`FATAL ${e}`); log("FATAL", String(e)); process.exitCode = 1; }
finally {
  for (const id of created) {
    try { await fresh(); await api.deleteMachine(id, `del-${id}-${Date.now()}`); results.notes.push(`deleted ${id}`); log("deleted", id); }
    catch (e) { results.notes.push(`DELETE FAILED ${id}: ${e}`); log("DELETE FAILED", id, String(e)); process.exitCode = 1; }
  }
  save();
}
