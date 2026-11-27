// Shared harness for the Freestyle mesh validation scripts (cx-0op, DESIGN.md section 1.4).
//
// Safety contract (shared account, production runs on it):
// - Every created VPC, tunnel, rule, VM and identity carries the prefix
//   `cmux-mesh-validation-<run id>` and is appended to a JSONL ledger the
//   moment the create call returns.
// - `withRun` deletes exactly the ledger ids at exit (normal exit, throw,
//   SIGINT, SIGTERM), by exact id. Nothing is ever listed and deleted.
// - At most MAX_LIVE resources exist at a time (rules count, except when a
//   script opts out for the rule-limit question).
// - A 429 or a burst of 5xx aborts the run, cleans up, and exits non-zero.
// - The API key is read from a file into memory. It is never printed,
//   logged, put on a command line, or written anywhere else.

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { generateKeyPairSync } from "node:crypto";

export const KEY_FILE =
  process.env.MESH_KEY_FILE ?? `${process.env.HOME}/.secrets/freestyle-cmux-next-dev-20261004.key`;
export const API = process.env.MESH_API_URL ?? "https://api.freestyle.sh";
export const RUN_ID = process.env.MESH_RUN_ID ?? new Date().toISOString().slice(0, 16).replace(/[-:T]/g, "").toLowerCase();
export const PREFIX = `cmux-mesh-validation-${RUN_ID}`;
export const MAX_LIVE = 20;
export const OUT_DIR = process.env.MESH_OUT_DIR ?? join(import.meta.dir, "out");
mkdirSync(OUT_DIR, { recursive: true });
export const LEDGER = process.env.MESH_LEDGER ?? join(OUT_DIR, `ledger-${RUN_ID}.jsonl`);

function readKey(file: string): string {
  const raw = readFileSync(file, "utf8").trim();
  // Accept a bare key or an env file with FREESTYLE_API_KEY=...
  const m = raw.match(/^FREESTYLE_API_KEY=(.*)$/m);
  return (m ? m[1] : raw).trim().replace(/^["']|["']$/g, "");
}
let KEY = "";
export function key(): string {
  if (!KEY) KEY = readKey(KEY_FILE);
  return KEY;
}
export function keyFrom(file: string): string {
  return readKey(file);
}

export class AccountTrouble extends Error {}

export type Kind = "rule" | "tunnel" | "vm" | "vpc" | "identity";
type LedgerRow = { t: string; run: string; op: "create" | "delete" | "gone"; kind: Kind; id: string; note?: string };

const live = new Map<string, Kind>(); // id -> kind, for resources this process created
export let allowManyRules = false;
export function setAllowManyRules(v: boolean) {
  allowManyRules = v;
}

function ledger(row: Omit<LedgerRow, "t" | "run">) {
  mkdirSync(dirname(LEDGER), { recursive: true });
  appendFileSync(LEDGER, JSON.stringify({ t: new Date().toISOString(), run: RUN_ID, ...row }) + "\n");
}

let fiveXX = 0;
export type Resp<T = any> = { status: number; json: T; ms: number; text: string };

export async function api<T = any>(
  method: string,
  path: string,
  body?: unknown,
  opts: { key?: string; allow?: number[]; quiet?: boolean } = {},
): Promise<Resp<T>> {
  const t0 = performance.now();
  const res = await fetch(`${API}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${opts.key ?? key()}`,
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  const ms = performance.now() - t0;
  let json: any = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text.slice(0, 300) };
  }
  if (res.status >= 500) {
    fiveXX++;
    if (fiveXX >= 3) throw new AccountTrouble(`3 consecutive 5xx; last ${method} ${path} -> ${res.status} ${text.slice(0, 200)}`);
  } else fiveXX = 0;
  if (res.status === 429) throw new AccountTrouble(`429 on ${method} ${path}: ${text.slice(0, 300)}`);
  if (res.status >= 400 && !(opts.allow ?? []).includes(res.status)) {
    throw new Error(`${method} ${path} -> ${res.status} ${text.slice(0, 400)}`);
  }
  return { status: res.status, json, ms, text };
}

function liveCount(includeRules: boolean) {
  let n = 0;
  for (const k of live.values()) if (includeRules || k !== "rule") n++;
  return n;
}
function guardCapacity(kind: Kind) {
  const n = liveCount(!(allowManyRules && kind === "rule"));
  if (!(allowManyRules && kind === "rule") && n >= MAX_LIVE) throw new Error(`refusing create: ${n} live resources (cap ${MAX_LIVE})`);
}
export function track(kind: Kind, id: string, note?: string) {
  live.set(id, kind);
  ledger({ op: "create", kind, id, note });
}

// A resource deleted upstream by cascade (a rule that named a deleted tunnel or
// VM). It leaves the live count; verify-gone.ts still checks it for 404.
export function forget(id: string, why: string) {
  if (live.delete(id)) ledger({ op: "gone", kind: "rule", id, note: why });
}

const PATHS: Record<Kind, (id: string) => string> = {
  rule: (id) => `/v5/firewall/rules/${id}`,
  tunnel: (id) => `/v5/tunnels/${id}`,
  vm: (id) => `/v5/vms/${id}`,
  vpc: (id) => `/v5/vpcs/${id}`,
  identity: (id) => `/v5/identities/${id}`,
};

// ---- creates (each records the id before returning) ----

export async function createVpc(name: string, extra: Record<string, unknown> = {}) {
  guardCapacity("vpc");
  const r = await api("POST", "/v5/vpcs", { displayName: `${PREFIX}-${name}`, ...extra });
  const id = r.json.id ?? r.json.vpcId;
  track("vpc", id, name);
  return { ...r.json, id, _ms: r.ms };
}

export type Keypair = { priv: string; pub: string };
export function wgKeypair(): Keypair {
  const { publicKey, privateKey } = generateKeyPairSync("x25519");
  const pub = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
  const priv = privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32).toString("base64");
  return { priv, pub };
}

export async function createTunnel(name: string, body: Record<string, unknown>, opts: { allow?: number[] } = {}) {
  guardCapacity("tunnel");
  const r = await api("POST", "/v5/tunnels", { displayName: `${PREFIX}-${name}`, ...body }, { allow: opts.allow });
  if (r.status >= 400) return { _status: r.status, _error: r.json, _ms: r.ms } as any;
  const id = r.json.tunnelId ?? r.json.id;
  track("tunnel", id, name);
  if (r.json.clientPrivateKey) {
    // A minted key would leave the device boundary. We always pass our own key, so this is a bug.
    throw new Error(`tunnel ${id} came back with a minted private key`);
  }
  return { ...r.json, id, _ms: r.ms, _status: r.status };
}

export async function createRule(name: string, source: unknown, destination: unknown, opts: { allow?: number[] } = {}) {
  guardCapacity("rule");
  const r = await api("POST", "/v5/firewall/rules", { action: "allow", source, destination, description: `${PREFIX}-${name}` }, opts);
  if (r.status >= 400) return { _status: r.status, _error: r.json, _ms: r.ms } as any;
  track("rule", r.json.id, name);
  return { ...r.json, _ms: r.ms, _status: r.status };
}

export async function createVm(name: string, body: Record<string, unknown>) {
  guardCapacity("vm");
  const req = {
    displayName: `${PREFIX}-${name}`,
    metadata: { purpose: "cmux-mesh-validation", run: RUN_ID },
    idleTimeoutSeconds: 300,
    ttlSeconds: 3 * 3600, // backstop: the platform deletes it even if this process dies
    snapshotId: "freestyle/ubuntu-sm",
    ...body,
  } as Record<string, any>;
  if (typeof req.idleTimeoutSeconds !== "number" || req.idleTimeoutSeconds > 300 || req.idleTimeoutSeconds < 1)
    throw new Error("idleTimeoutSeconds must be 1..300 for validation VMs");
  const r = await api("POST", "/v5/vms", req);
  const id = r.json.id ?? r.json.vmId;
  track("vm", id, `${name} ${JSON.stringify(r.json.resources ?? null)}`);
  return { ...r.json, id, _ms: r.ms };
}

export async function createIdentity(name: string) {
  guardCapacity("identity");
  const r = await api("POST", "/v5/identities", {});
  const id = r.json.id ?? r.json.identityId;
  track("identity", id, name);
  return { ...r.json, id, _ms: r.ms };
}

// ---- deletes (exact id only) ----

export async function del(kind: Kind, id: string): Promise<{ status: number; ms: number }> {
  for (let attempt = 0; ; attempt++) {
    const r = await api("DELETE", PATHS[kind](id), undefined, { allow: [404, 409] });
    if (r.status === 409 && kind === "vpc" && attempt < 30) {
      await sleep(2000); // VPC delete conflicts for a few seconds after member deletes
      continue;
    }
    if (r.status < 300 || r.status === 404) {
      live.delete(id);
      ledger({ op: "delete", kind, id, note: String(r.status) });
    }
    return { status: r.status, ms: r.ms };
  }
}

const ORDER: Kind[] = ["rule", "tunnel", "vm", "identity", "vpc"];
export async function cleanup(ids?: Map<string, Kind>) {
  const set = ids ?? live;
  const out: string[] = [];
  for (const kind of ORDER) {
    const batch = [...set].filter(([, k]) => k === kind).map(([id]) => id);
    for (let i = 0; i < batch.length; i += 8) {
      const res = await Promise.all(
        batch.slice(i, i + 8).map(async (id) => {
          try {
            const r = await del(kind, id);
            return `${kind} ${id} ${r.status}`;
          } catch (e) {
            return `${kind} ${id} ERROR ${(e as Error).message.slice(0, 120)}`;
          }
        }),
      );
      out.push(...res);
    }
  }
  return out;
}

export function liveIds() {
  return new Map(live);
}

let cleaning: Promise<unknown> | null = null;
export async function withRun(name: string, fn: () => Promise<void>) {
  const onSignal = (sig: string) => {
    console.error(`[${name}] ${sig}: cleaning up ${live.size} resources`);
    cleaning ??= cleanup().then((r) => console.error(r.join("\n")));
    cleaning.finally(() => process.exit(130));
  };
  process.on("SIGINT", () => onSignal("SIGINT"));
  process.on("SIGTERM", () => onSignal("SIGTERM"));
  process.on("SIGHUP", () => onSignal("SIGHUP"));
  let code = 0;
  try {
    await fn();
  } catch (e) {
    code = e instanceof AccountTrouble ? 3 : 1;
    console.error(`[${name}] FAILED: ${(e as Error).stack ?? e}`);
  } finally {
    if (live.size) {
      cleaning ??= cleanup();
      const r = (await cleaning) as string[];
      console.error(`[${name}] cleanup:\n${r.join("\n")}`);
    }
  }
  process.exit(code);
}

// ---- helpers ----

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
export function pct(xs: number[], p: number) {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))];
}
export function summary(xs: number[], unit = "ms") {
  const f = (v: number) => (Number.isFinite(v) ? v.toFixed(1) : "n/a");
  return `n=${xs.length} p50=${f(pct(xs, 50))}${unit} p95=${f(pct(xs, 95))}${unit} min=${f(Math.min(...xs))}${unit} max=${f(Math.max(...xs))}${unit}`;
}
export function result(q: string, obj: Record<string, unknown>) {
  const line = JSON.stringify({ q, run: RUN_ID, at: new Date().toISOString(), ...obj });
  console.log(line);
  appendFileSync(join(OUT_DIR, `results-${RUN_ID}.jsonl`), line + "\n");
}

export async function exec(vmId: string, command: string, timeoutMs = 120_000) {
  const r = await api("POST", `/v5/vms/${vmId}/exec-await`, { command, timeoutMs }, { allow: [400, 408, 500, 504] });
  return { ...r.json, _status: r.status, _ms: r.ms } as { stdout?: string; stderr?: string; statusCode?: number; _status: number; _ms: number };
}

export async function waitRunning(vmId: string, timeoutMs = 120_000) {
  const t0 = Date.now();
  for (;;) {
    const r = await api("GET", `/v5/vms/${vmId}`);
    if (r.json.state === "running") return r.json;
    if (Date.now() - t0 > timeoutMs) throw new Error(`vm ${vmId} not running after ${timeoutMs} ms: ${r.json.state}`);
    await sleep(1000);
  }
}

export function vmVpcIpv4(vm: any): string | undefined {
  const n = (vm.vpcs ?? vm.networks ?? [])[0];
  return n?.ipv4 ?? undefined;
}

export const exists = existsSync;
