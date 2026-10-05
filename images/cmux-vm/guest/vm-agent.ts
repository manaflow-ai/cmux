#!/usr/local/bin/bun
/**
 * cmux VM agent: bind, status report and events for a cmux-next Cloud machine
 * (plans/cmux-next/cloud-client-contract.md 1.7 "bind", backend/catalog/cloud-vectors.json
 * cases machine.bind, vm.status.report, vm.event.emit; plans/cmux-next/cloud-automation.md).
 *
 * Interim: a Bun program baked into the image. vm-image.md places the bind agent in the
 * Rust `cmux host` role; this file is the contract-complete stand-in until that role exists.
 *
 * Lifecycle (no polling):
 * - systemd `cmux-vm-agent.path` starts the service when the driver writes
 *   /var/lib/cmux/bind.json (create, retry, restore); the service also starts at boot when
 *   bound.json exists. While running, a directory watch catches a new bind.json (epoch raise).
 * - Bind: per-clone ES256 P-256 install key (new when the MMDS instance id changes),
 *   per-clone WireGuard key, POST /v1/cloud/bind (the one-time token is the credential),
 *   bound.json written before bind.json is removed.
 * - Tokens: /v1/auth/challenge + /v1/auth/token, signing the server's prefix + nonce after
 *   checking the prefix names this environment and install.
 * - cloud.vm.status.report: once after bind and after every start, on change (activity from
 *   the local socket), at most 1 per 10 s (latest wins), plus a heartbeat deadline 1 h after
 *   the last accepted report; failures back off (retry_after_ms honored) up to 10 min.
 * - cloud.vm.event.emit: v1 kinds from the local socket, rate limit honored.
 * - Local socket /run/cmux-vm-agent/agent.sock (root and group cmux): JSON lines
 *   {"activity": {...}} or {"event": {"kind", "at", "data"}}.
 */
import { spawnSync } from "node:child_process";
import { chmodSync, chownSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, watch, writeFileSync } from "node:fs";
import { connect, createServer, type Socket } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const BIND_FILE = "/var/lib/cmux/bind.json";
export const BOUND_FILE = "/var/lib/cmux/bound.json";
export const INSTALL_KEY_FILE = "/var/lib/cmux/install/key.json";
export const WG_KEY_FILE = "/var/lib/cmux/wg/key.json";
/** Own runtime dir: the bake and the boot supervisor clear /run/cmux. */
export const AGENT_SOCKET = "/run/cmux-vm-agent/agent.sock";
export const DAEMON_INFO_FILE = "/etc/cmux/daemon.json";
/** The baked daemon's control socket path (the bake finds it with `ss` and records it). */
export const DAEMON_SOCKET_FILE = "/etc/cmux/daemon-socket";
export const MACHINE_ID_FILES = ["/etc/machine-id", "/var/lib/dbus/machine-id"] as const;
export const MACHINE_ID_INSTANCE_FILE = "/var/lib/cmux/machine-id.instance";
/**
 * Daemon capabilities a Cloud client gates on (first-party-apps/cloud/server: fs/link_files.rs
 * fs-v1, ports/loopback.rs loopback-forward-v1). The daemon advertises about 70 and bind accepts
 * at most 32, so bind carries only these, plus the agent's own.
 */
export const CLOUD_GATED_DAEMON_CAPABILITIES = ["fs-v1", "loopback-forward-v1"] as const;
/** The agent's own capability; `activity` is added only when an activity sender feeds the socket. */
export const AGENT_CAPABILITY = "vm-agent-v1";
export const ACTIVITY_CAPABILITY = "activity";
/** False until the daemon (or its hooks) sends activity lines to AGENT_SOCKET (cloud-automation.md 17). */
export const ACTIVITY_SENDER_EXISTS = false;

export type Env = "dev" | "stg" | "prod";
/** The only API origin each environment may bind to (the driver writes api_origin; the image refuses anything else). */
export const API_ORIGINS: Readonly<Record<Env, string>> = {
  dev: "https://cmux-api-development.debussy.workers.dev",
  stg: "https://cloud-api-staging.cmux.dev",
  prod: "https://cloud-api.cmux.dev",
};
/** The Worker's ENVIRONMENT for each bind env: the auth challenge prefix names it. */
export const AUTH_ENVIRONMENT: Readonly<Record<Env, string>> = { dev: "development", stg: "staging", prod: "production" };

export const VM_EVENT_KINDS = [
  "agent.started",
  "agent.finished",
  "agent.needs_input",
  "notification",
  "browser.lease.changed",
  "cua.session.started",
  "cua.session.ended",
  "service.port.opened",
  "service.port.closed",
] as const;
const VM_EVENT_DATA_MAX_BYTES = 4096;

// ---------------------------------------------------------------- storage and time

export interface Store {
  read(file: string): string | null;
  write(file: string, text: string, mode: number): void;
  remove(file: string): void;
}

/** Test store: also records each file's mode. */
export class MemoryStore implements Store {
  private files = new Map<string, { text: string; mode: number }>();
  read = (file: string) => this.files.get(file)?.text ?? null;
  write = (file: string, text: string, mode: number) => void this.files.set(file, { text, mode });
  remove = (file: string) => void this.files.delete(file);
  modeOf = (file: string) => this.files.get(file)?.mode ?? null;
}

/** Atomic writes (temp file + rename) in root-only directories. */
export class FileStore implements Store {
  read(file: string): string | null {
    try {
      return readFileSync(file, "utf8");
    } catch {
      return null;
    }
  }
  write(file: string, text: string, mode: number): void {
    mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const tmp = `${file}.tmp-${process.pid}`;
    writeFileSync(tmp, text, { mode });
    chmodSync(tmp, mode);
    renameSync(tmp, file);
  }
  remove(file: string): void {
    rmSync(file, { force: true });
  }
}

export interface Clock {
  now(): number;
  /** One-shot timer; returns its cancel function. */
  setTimer(ms: number, fn: () => void): () => void;
}

export const systemClock: Clock = {
  now: () => Date.now(),
  setTimer: (ms, fn) => {
    const t = setTimeout(fn, ms);
    return () => clearTimeout(t);
  },
};

const log = (message: string) => console.log(`cmux-vm-agent: ${message}`);

// ---------------------------------------------------------------- bind file

export class BindFileError extends Error {}

export type BindFile = { team: string; machine: string; bind_token: string; api_origin: string; env: Env };

const TEAM_ID = /^team_[a-z0-9]{20}$/;
const MACHINE_ID = /^vm_[a-z0-9]{20}$/;
const BIND_TOKEN = /^[A-Za-z0-9_-]{16,256}$/;

export function parseBindFile(text: string): BindFile {
  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(text) as Record<string, unknown>;
  } catch {
    throw new BindFileError("bind.json is not JSON");
  }
  const { team, machine, bind_token, api_origin, env } = raw;
  if (typeof team !== "string" || !TEAM_ID.test(team)) throw new BindFileError("bind.json: bad team");
  if (typeof machine !== "string" || !MACHINE_ID.test(machine)) throw new BindFileError("bind.json: bad machine");
  if (typeof bind_token !== "string" || !BIND_TOKEN.test(bind_token)) throw new BindFileError("bind.json: bad bind_token");
  if (env !== "dev" && env !== "stg" && env !== "prod") throw new BindFileError("bind.json: unknown env");
  if (api_origin !== API_ORIGINS[env]) throw new BindFileError(`bind.json: api_origin is not the ${env} origin`);
  return { team, machine, bind_token, api_origin, env };
}

// ---------------------------------------------------------------- keys

export type InstallKey = { privateKey: CryptoKey; publicJwk: JsonWebKey; rotated: boolean };

const publicPart = (jwk: JsonWebKey): JsonWebKey => ({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y });

/** The VM's ES256 P-256 install key, one per clone: a new MMDS instance id makes a new key. */
export async function ensureInstallKey(store: Store, instanceId: string): Promise<InstallKey> {
  const saved = store.read(INSTALL_KEY_FILE);
  if (saved) {
    const parsed = JSON.parse(saved) as { instance_id: string; private_jwk: JsonWebKey };
    if (parsed.instance_id === instanceId) {
      const privateKey = await crypto.subtle.importKey("jwk", parsed.private_jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
      return { privateKey, publicJwk: publicPart(parsed.private_jwk), rotated: false };
    }
  }
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  store.write(INSTALL_KEY_FILE, `${JSON.stringify({ instance_id: instanceId, private_jwk: privateJwk })}\n`, 0o600);
  const privateKey = await crypto.subtle.importKey("jwk", privateJwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return { privateKey, publicJwk: publicPart(privateJwk), rotated: true };
}

/** ES256 over the UTF-8 message; WebCrypto returns raw r||s (64 bytes), sent base64url. */
export async function signMessage(privateKey: CryptoKey, message: string): Promise<string> {
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, new TextEncoder().encode(message));
  return Buffer.from(sig).toString("base64url");
}

/** Per-clone WireGuard key (wireguard-tools in the base). The link's VM endpoint reads the private key from WG_KEY_FILE. */
export function ensureWgKey(store: Store, instanceId: string): { publicKey: string } {
  const saved = store.read(WG_KEY_FILE);
  if (saved) {
    const parsed = JSON.parse(saved) as { instance_id: string; public_key: string };
    if (parsed.instance_id === instanceId) return { publicKey: parsed.public_key };
  }
  const priv = spawnSync("wg", ["genkey"], { encoding: "utf8" });
  if (priv.status !== 0) throw new Error("wg genkey failed");
  const pub = spawnSync("wg", ["pubkey"], { input: priv.stdout, encoding: "utf8" });
  if (pub.status !== 0) throw new Error("wg pubkey failed");
  const publicKey = pub.stdout.trim();
  store.write(WG_KEY_FILE, `${JSON.stringify({ instance_id: instanceId, private_key: priv.stdout.trim(), public_key: publicKey })}\n`, 0o600);
  return { publicKey };
}

/**
 * Per-clone machine-id (vm-image.md 6.3): a clone shares the snapshot's id until this runs.
 * Same trigger as the install key: a new MMDS instance id. Returns whether it changed.
 */
export function ensureMachineId(store: Store, instanceId: string, randomHex: () => string = () => crypto.randomUUID().replaceAll("-", "")): boolean {
  if (store.read(MACHINE_ID_INSTANCE_FILE)?.trim() === instanceId) return false;
  const id = randomHex().toLowerCase();
  if (!/^[0-9a-f]{32}$/.test(id)) throw new Error("machine-id generator returned a bad id");
  for (const file of MACHINE_ID_FILES) store.write(file, `${id}\n`, 0o444);
  store.write(MACHINE_ID_INSTANCE_FILE, `${instanceId}\n`, 0o600);
  return true;
}

// ---------------------------------------------------------------- daemon info

type Identify = { version?: string; build_commit?: string; capabilities?: unknown };

/** One `identify` on the daemon's control socket (newline-delimited JSON), bounded by timeoutMs. */
export function queryDaemonIdentify(socketPath: string, timeoutMs = 2_000): Promise<Identify> {
  return new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    let buffer = "";
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("daemon identify timed out"));
    }, timeoutMs);
    const done = (fn: () => void) => {
      clearTimeout(timer);
      socket.destroy();
      fn();
    };
    socket.setEncoding("utf8");
    socket.on("error", (error) => done(() => reject(error)));
    socket.on("connect", () => socket.write(`${JSON.stringify({ id: 1, cmd: "identify" })}\n`));
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      const nl = buffer.indexOf("\n");
      if (nl < 0) return;
      const reply = JSON.parse(buffer.slice(0, nl)) as { ok?: boolean; data?: Identify };
      done(() => (reply.ok === true && reply.data ? resolve(reply.data) : reject(new Error("daemon identify refused"))));
    });
  });
}

/** The daemon block bind and status reports send: from identify, at most 32 capabilities. */
export function daemonInfoFromIdentify(identify: Identify, options: { activitySender: boolean }): DaemonInfo {
  const advertised = Array.isArray(identify.capabilities) ? identify.capabilities.filter((c): c is string => typeof c === "string") : [];
  const gated = CLOUD_GATED_DAEMON_CAPABILITIES.filter((c) => advertised.includes(c));
  const capabilities = [...gated, AGENT_CAPABILITY, ...(options.activitySender ? [ACTIVITY_CAPABILITY] : [])];
  const build = typeof identify.build_commit === "string" && identify.build_commit ? `+${identify.build_commit.slice(0, 12)}` : "";
  const version = `${typeof identify.version === "string" && identify.version ? identify.version : "unknown"}${build}`.slice(0, 64);
  return { version, capabilities };
}

/** Live identify first; the bake-recorded daemon.json when the daemon does not answer. Never an empty list. */
export async function resolveDaemonInfo(store: Store, options: { activitySender: boolean }): Promise<DaemonInfo> {
  const socketPath = store.read(DAEMON_SOCKET_FILE)?.trim();
  if (socketPath) {
    try {
      return daemonInfoFromIdentify(await queryDaemonIdentify(socketPath), options);
    } catch {
      // fall through to the recorded file
    }
  }
  const recorded = store.read(DAEMON_INFO_FILE);
  if (!recorded) throw new Error("no daemon identify and no recorded daemon.json");
  const info = JSON.parse(recorded) as DaemonInfo;
  const capabilities = info.capabilities.filter((c) => c !== ACTIVITY_CAPABILITY);
  return { version: info.version, capabilities: options.activitySender ? [...capabilities, ACTIVITY_CAPABILITY] : capabilities };
}

// ---------------------------------------------------------------- bind

export type DaemonInfo = { version: string; capabilities: string[] };
export type Bound = { machine: string; team: string; host: string; epoch: number; install: string; user: string; grant: string; env: Env; api_origin: string; keyset: unknown; bound_at: number };
export type BindResult = { kind: "none" } | { kind: "bound"; bound: Bound } | { kind: "refused"; code: string } | { kind: "invalid"; message: string } | { kind: "retry"; message: string };

type BindDeps = { fetch: typeof fetch; store: Store; key: InstallKey; wg: () => Promise<{ publicKey: string }>; daemon: () => Promise<DaemonInfo>; now?: () => number };

type BindAnswer = { ok?: boolean; value?: { machine: string; host: string; epoch: number; keyset: unknown; install: { id: string; user: string; grant: string } }; error?: { code?: string } };

async function postJson(fetchFn: typeof fetch, url: string, body: unknown, bearer?: string): Promise<{ status: number; body: Record<string, any> }> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  const res = await fetchFn(url, { method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(20_000) });
  let parsed: Record<string, any> = {};
  try {
    parsed = (await res.json()) as Record<string, any>;
  } catch {
    parsed = {};
  }
  return { status: res.status, body: parsed };
}

/** Spends bind.json's one-time token. A 4xx answer is final (the token is spent or invalid), so bind.json goes either way. */
export async function bindMachine(deps: BindDeps): Promise<BindResult> {
  const text = deps.store.read(BIND_FILE);
  if (text === null) return { kind: "none" };
  let file: BindFile;
  try {
    file = parseBindFile(text);
  } catch (error) {
    deps.store.remove(BIND_FILE);
    return { kind: "invalid", message: String((error as Error).message) };
  }
  const body = { team: file.team, machine: file.machine, bind_token: file.bind_token, wg_public_key: (await deps.wg()).publicKey, daemon: await deps.daemon(), install_public_jwk: deps.key.publicJwk };
  let answer: { status: number; body: BindAnswer };
  try {
    answer = await postJson(deps.fetch, `${file.api_origin}/v1/cloud/bind`, body);
  } catch (error) {
    return { kind: "retry", message: String(error) };
  }
  if (answer.status >= 500 || answer.status === 429) return { kind: "retry", message: `HTTP ${answer.status}` };
  const value = answer.body.value;
  if (answer.status !== 200 || answer.body.ok !== true || !value) {
    deps.store.remove(BIND_FILE);
    return { kind: "refused", code: answer.body.error?.code ?? `http.${answer.status}` };
  }
  const bound: Bound = { machine: value.machine, team: file.team, host: value.host, epoch: value.epoch, install: value.install.id, user: value.install.user, grant: value.install.grant, env: file.env, api_origin: file.api_origin, keyset: value.keyset, bound_at: (deps.now ?? Date.now)() };
  deps.store.write(BOUND_FILE, `${JSON.stringify(bound)}\n`, 0o600);
  deps.store.remove(BIND_FILE);
  return { kind: "bound", bound };
}

// ---------------------------------------------------------------- API client

export class CloudClient {
  private cached: { token: string; expiresAt: number } | null = null;
  constructor(private readonly deps: { fetch: typeof fetch; bound: Bound; key: InstallKey; clock: Clock }) {}

  private url(p: string): string {
    return `${this.deps.bound.api_origin}${p}`;
  }

  async token(): Promise<string> {
    const { bound, key, clock } = this.deps;
    if (this.cached && this.cached.expiresAt - 60_000 > clock.now()) return this.cached.token;
    const challenge = await postJson(this.deps.fetch, this.url("/v1/auth/challenge"), { user: bound.user, install: bound.install });
    const expected = `cmux-auth-v1\n${AUTH_ENVIRONMENT[bound.env]}\n${bound.install}\n`;
    if (challenge.status !== 200 || challenge.body.install !== bound.install) throw new Error(`challenge refused: HTTP ${challenge.status}`);
    if (challenge.body.message_prefix !== expected) throw new Error("challenge message prefix names another environment or install; not signing");
    const signature = await signMessage(key.privateKey, `${expected}${String(challenge.body.nonce)}`);
    const token = await postJson(this.deps.fetch, this.url("/v1/auth/token"), { user: bound.user, install: bound.install, nonce: challenge.body.nonce, signature });
    if (token.status !== 200 || token.body.token_type !== "Bearer" || typeof token.body.access_token !== "string") throw new Error(`token refused: HTTP ${token.status} ${String(token.body.code ?? "")}`);
    this.cached = { token: token.body.access_token, expiresAt: Number(token.body.expires_at) };
    return this.cached.token;
  }

  /** One mutation on /v1/ops. A 401 or 403 drops the cached token and retries once. */
  async op(op: string, params: Record<string, unknown>): Promise<{ status: number; body: Record<string, any> }> {
    let answer = await postJson(this.deps.fetch, this.url("/v1/ops"), { op, params }, await this.token());
    if (answer.status === 401 || answer.status === 403) {
      this.cached = null;
      answer = await postJson(this.deps.fetch, this.url("/v1/ops"), { op, params }, await this.token());
    }
    return answer;
  }
}

// ---------------------------------------------------------------- backoff

class Backoff {
  private attempt = 0;
  constructor(private readonly initialMs: number, private readonly maxMs: number, private readonly random: () => number) {}
  /** Exponential with ±10% jitter, at least retryAfterMs, never above maxMs. */
  next(retryAfterMs = 0): number {
    const base = Math.min(this.maxMs, this.initialMs * 2 ** this.attempt);
    this.attempt += 1;
    const jittered = base * (0.9 + 0.2 * this.random());
    return Math.min(this.maxMs, Math.max(retryAfterMs, Math.round(jittered)));
  }
  reset(): void {
    this.attempt = 0;
  }
}

const retryAfter = (body: Record<string, any>): number => Number(body.error?.details?.retry_after_ms ?? 0) || 0;

// ---------------------------------------------------------------- status report

export type Activity = { active_sessions: number; last_user_input_at?: number; last_agent_action_at?: number };
type ReporterOptions = {
  client: CloudClient;
  clock: Clock;
  machine: string;
  daemon: DaemonInfo;
  heartbeatMs?: number;
  minIntervalMs?: number;
  initialBackoffMs?: number;
  maxBackoffMs?: number;
  random?: () => number;
};

/**
 * cloud.vm.status.report sender. Three timers at most, each one-shot: the 10 s window, the
 * retry after a failure, and the heartbeat deadline (re-armed after each accepted report and
 * paused while a retry is pending, so a failing machine holds exactly one timer).
 */
export class StatusReporter {
  private activity: Activity = { active_sessions: 0 };
  private state: "running" | "degraded" | "stopping" = "running";
  private dirty = false;
  private lastSentAt: number | null = null;
  private inFlight: Promise<void> | null = null;
  private cancelWindow: (() => void) | null = null;
  private cancelRetry: (() => void) | null = null;
  private cancelHeartbeat: (() => void) | null = null;
  private readonly backoff: Backoff;
  private readonly heartbeatMs: number;
  private readonly minIntervalMs: number;

  constructor(private readonly o: ReporterOptions) {
    this.heartbeatMs = o.heartbeatMs ?? 3_600_000;
    this.minIntervalMs = o.minIntervalMs ?? 10_000;
    this.backoff = new Backoff(o.initialBackoffMs ?? 5_000, o.maxBackoffMs ?? 600_000, o.random ?? Math.random);
  }

  update(change: Partial<Activity>): void {
    this.activity = { ...this.activity, ...change };
    this.trigger("change");
  }

  setState(state: "running" | "degraded" | "stopping"): void {
    this.state = state;
    this.trigger("state");
  }

  /** Mark a report due (bind, start, change, heartbeat) and send it as soon as the window allows. */
  trigger(_reason: string): void {
    this.dirty = true;
    this.schedule();
  }

  async settled(): Promise<void> {
    while (this.inFlight) await this.inFlight;
  }

  private schedule(): void {
    if (this.inFlight || this.cancelRetry || this.cancelWindow || !this.dirty) return;
    const wait = this.lastSentAt === null ? 0 : this.lastSentAt + this.minIntervalMs - this.o.clock.now();
    if (wait <= 0) {
      this.send();
      return;
    }
    this.cancelWindow = this.o.clock.setTimer(wait, () => {
      this.cancelWindow = null;
      this.schedule();
    });
  }

  private send(): void {
    this.dirty = false;
    this.lastSentAt = this.o.clock.now();
    const params = { machine: this.o.machine, state: this.state, daemon: this.o.daemon, activity: { ...this.activity } };
    this.inFlight = this.o.client
      .op("cloud.vm.status.report", params)
      .then((answer) => (answer.status === 200 && answer.body.ok === true ? this.accepted() : this.failed(retryAfter(answer.body))))
      .catch(() => this.failed(0))
      .finally(() => {
        this.inFlight = null;
        this.schedule();
      });
  }

  private accepted(): void {
    this.backoff.reset();
    this.cancelHeartbeat?.();
    this.cancelHeartbeat = this.o.clock.setTimer(this.heartbeatMs, () => {
      this.cancelHeartbeat = null;
      this.trigger("heartbeat");
    });
  }

  private failed(retryAfterMs: number): void {
    this.dirty = true;
    this.cancelHeartbeat?.();
    this.cancelHeartbeat = null;
    this.cancelRetry = this.o.clock.setTimer(this.backoff.next(retryAfterMs), () => {
      this.cancelRetry = null;
      this.send();
    });
  }
}

// ---------------------------------------------------------------- events

type QueuedEvent = { kind: string; at: number; data: unknown };

/** cloud.vm.event.emit in order; rate limits wait retry_after_ms; an invalid event is dropped and logged. */
export class EventSender {
  private queue: QueuedEvent[] = [];
  private inFlight: Promise<void> | null = null;
  private cancelRetry: (() => void) | null = null;
  private readonly backoff: Backoff;

  constructor(private readonly o: { client: CloudClient; clock: Clock; machine: string; random?: () => number }) {
    this.backoff = new Backoff(1_000, 600_000, o.random ?? Math.random);
  }

  emit(kind: string, at: number, data: unknown): void {
    if (!(VM_EVENT_KINDS as readonly string[]).includes(kind)) throw new Error(`unknown event kind ${kind}`);
    if (Buffer.byteLength(JSON.stringify(data ?? {})) > VM_EVENT_DATA_MAX_BYTES) throw new Error("event data over 4 KB");
    this.queue.push({ kind, at, data });
    this.pump();
  }

  async settled(): Promise<void> {
    while (this.inFlight) await this.inFlight;
  }

  private pump(): void {
    if (this.inFlight || this.cancelRetry || this.queue.length === 0) return;
    const head = this.queue[0];
    this.inFlight = this.o.client
      .op("cloud.vm.event.emit", { machine: this.o.machine, kind: head.kind, at: head.at, data: head.data })
      .then((answer) => this.answered(answer))
      .catch(() => this.retryIn(this.backoff.next()))
      .finally(() => {
        this.inFlight = null;
        this.pump();
      });
  }

  private answered(answer: { status: number; body: Record<string, any> }): void {
    if (answer.status === 200 && answer.body.ok === true) {
      this.queue.shift();
      this.backoff.reset();
      return;
    }
    const code = String(answer.body.error?.code ?? answer.body.code ?? "");
    if (code === "cloud.rate_limited" || answer.status >= 500) {
      this.retryIn(code === "cloud.rate_limited" ? Math.max(retryAfter(answer.body), 1) : this.backoff.next());
      return;
    }
    log(`event ${this.queue[0]?.kind} dropped: ${code || `HTTP ${answer.status}`}`);
    this.queue.shift();
  }

  private retryIn(ms: number): void {
    this.cancelRetry = this.o.clock.setTimer(ms, () => {
      this.cancelRetry = null;
      this.pump();
    });
  }
}

// ---------------------------------------------------------------- guest wiring

/** One MMDS read (IMDSv2 style, 2 s timeouts); never in a loop. */
export async function readInstanceId(fetchFn: typeof fetch = fetch): Promise<string> {
  const tokenRes = await fetchFn("http://169.254.169.254/latest/api/token", { method: "PUT", headers: { "X-metadata-token-ttl-seconds": "60" }, signal: AbortSignal.timeout(2_000) });
  const token = await tokenRes.text();
  const res = await fetchFn("http://169.254.169.254/latest/meta-data/instance-id", { headers: { "X-aws-ec2-metadata-token": token }, signal: AbortSignal.timeout(2_000) });
  const id = (await res.text()).trim();
  if (!res.ok || id === "") throw new Error("MMDS instance id unavailable");
  return id;
}

type Running = { reporter: StatusReporter; events: EventSender };

function handleLine(line: string, running: Running | null): void {
  if (!running || line.trim() === "") return;
  try {
    const msg = JSON.parse(line) as { activity?: Partial<Activity>; event?: QueuedEvent };
    if (msg.activity) running.reporter.update(msg.activity);
    if (msg.event) running.events.emit(msg.event.kind, msg.event.at, msg.event.data);
  } catch (error) {
    log(`socket line refused: ${String((error as Error).message)}`);
  }
}

function serveSocket(current: () => Running | null): void {
  mkdirSync(path.dirname(AGENT_SOCKET), { recursive: true, mode: 0o755 });
  rmSync(AGENT_SOCKET, { force: true });
  const server = createServer((socket: Socket) => {
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      if (buffer.length > 64 * 1024) socket.destroy();
      let nl = buffer.indexOf("\n");
      while (nl >= 0) {
        handleLine(buffer.slice(0, nl), current());
        buffer = buffer.slice(nl + 1);
        nl = buffer.indexOf("\n");
      }
    });
  });
  server.listen(AGENT_SOCKET, () => {
    const gid = Number(spawnSync("id", ["-g", "cmux"], { encoding: "utf8" }).stdout.trim());
    if (Number.isInteger(gid) && gid > 0) chownSync(AGENT_SOCKET, 0, gid);
    chmodSync(AGENT_SOCKET, 0o660);
  });
}

async function main(): Promise<void> {
  const store = new FileStore();
  if (process.argv.includes("--print-daemon-info")) {
    const socketPath = store.read(DAEMON_SOCKET_FILE)?.trim();
    if (!socketPath) throw new Error(`${DAEMON_SOCKET_FILE} is missing`);
    console.log(JSON.stringify(daemonInfoFromIdentify(await queryDaemonIdentify(socketPath, 10_000), { activitySender: false })));
    return;
  }
  const clock = systemClock;
  let running: Running | null = null;
  const bindBackoff = new Backoff(2_000, 600_000, Math.random);
  let binding = false;

  const start = async (bound: Bound, key: InstallKey) => {
    const client = new CloudClient({ fetch, bound, key, clock });
    const daemon = await resolveDaemonInfo(store, { activitySender: ACTIVITY_SENDER_EXISTS });
    running = { reporter: new StatusReporter({ client, clock, machine: bound.machine, daemon }), events: new EventSender({ client, clock, machine: bound.machine }) };
    running.reporter.trigger("start");
  };

  const bindNow = async (): Promise<void> => {
    if (binding || !existsSync(BIND_FILE)) return;
    binding = true;
    try {
      const instanceId = await readInstanceId();
      if (ensureMachineId(store, instanceId)) {
        // journald files entries under /var/log/journal/<machine-id>; restart it so it and
        // journalctl agree on the new id (dbus-daemon keeps the old id until its next start).
        spawnSync("systemctl", ["restart", "systemd-journald"], { stdio: "ignore" });
        log("machine-id regenerated for this clone");
      }
      const key = await ensureInstallKey(store, instanceId);
      const result = await bindMachine({ fetch, store, key, wg: async () => ensureWgKey(store, instanceId), daemon: () => resolveDaemonInfo(store, { activitySender: ACTIVITY_SENDER_EXISTS }) });
      log(`bind: ${result.kind}${"code" in result ? ` ${result.code}` : ""}${"message" in result ? ` ${result.message}` : ""}`);
      if (result.kind === "bound") {
        bindBackoff.reset();
        await start(result.bound, key);
      } else if (result.kind === "retry") {
        clock.setTimer(bindBackoff.next(), () => void bindNow());
      }
    } finally {
      binding = false;
    }
  };

  serveSocket(() => running);
  watch(path.dirname(BIND_FILE), (_event, name) => {
    if (name === path.basename(BIND_FILE)) void bindNow();
  });
  if (existsSync(BIND_FILE)) {
    await bindNow();
  } else {
    const saved = store.read(BOUND_FILE);
    if (!saved) {
      log("no bind.json and no bound.json; waiting for bind.json");
      return;
    }
    const instanceId = await readInstanceId();
    const key = await ensureInstallKey(store, instanceId);
    if (key.rotated) {
      log("instance id changed since bind and no new bind.json; not reporting with a key the server does not know");
      return;
    }
    await start(JSON.parse(saved) as Bound, key);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`cmux-vm-agent: ${String(error)}`);
    process.exit(1);
  });
}
