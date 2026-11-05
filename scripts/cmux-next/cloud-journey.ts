#!/usr/bin/env bun
/**
 * The NEXT Cloud journey: one command checks a backend end to end, with no app build.
 *
 *   bun scripts/cmux-next/cloud-journey.ts --backend staging
 *   bun scripts/cmux-next/cloud-journey.ts --backend preview-35100 --out /tmp/journey
 *   bun scripts/cmux-next/cloud-journey.ts --backend prod --credentials ~/.secrets/cmuxterm-prod.env --team team_...
 *   bun scripts/cmux-next/cloud-journey.ts --backend local            # wrangler dev on 127.0.0.1:8787
 *   bun scripts/cmux-next/cloud-journey.ts --api https://cmux-api-preview-35100.debussy.workers.dev --stack dev
 *   bun scripts/cmux-next/cloud-journey.ts --app-cli "$APP/Contents/Resources/bin/cmux" --socket /tmp/cmux-debug-TAG.sock
 *     (the commands a person runs, through a running NEXT build's CLI: list-machines, vm token create,
 *     new-machine, machine-status, exec, start-session, start-chat --wait, kill-machine; cmux#35086)
 *   bun scripts/cmux-next/cloud-journey.ts --backend prod --credentials F --machine vm_... --keyed-start --model stub
 *     (an existing machine, kept: no create, pause or delete; the dev machine of scripts/cmux-next/cloud-devloop.ts.
 *     --keyed-start runs the app's keyed acpmux start (POST .../acpmux/keyed-start) and checks the keyed daemon still
 *     serves after acpmux.service's restart delay: the take-over race of cmux-platform#845)
 *
 * It signs in as the agent test account (Stack password sign-in; CMUX_DOGFOOD_STACK_EMAIL and
 * CMUX_DOGFOOD_STACK_PASSWORD from the environment or a KEY=value --credentials file; or, in a GitHub Actions
 * job with `id-token: write`, --sign-in oidc: the job's OIDC token for a short session, no stored password,
 * hq#7076) and walks the
 * same routes the app and the cmux CLI use, against the cmux API Worker (which forwards Cloud ops to
 * cmux-platform):
 *
 *   health -> sign in -> user.ensure -> install token -> create machine -> running (status) -> listed
 *   -> first exec -> pass Claude login -> start agent (acpmux on the machine) -> send chat -> reply -> connect (connect_info
 *   + link_token + link dial) -> handoff record -> sync push/pull (a folder round trip) -> pause -> resume -> delete
 *
 * Each step prints PASS/FAIL/SKIP with its latency; --out DIR also gets journey.json (the steps) and
 * summary.md (a table for a PR comment or job summary). The machine this run made is deleted at the
 * end, pass or fail, by its exact id, unless --keep. Exit 0 only when no step failed.
 *
 * Exec goes the CLI's own way (`cmux machine access exec`: a client session minted at
 * POST /v1/cloud/machines/{id}/client-session, then the provider's exec-await). --cmux PATH runs every
 * exec through that cmux binary instead, so a CLI change is checked by the same journey.
 *
 * Pass Claude login is the Mac's login copy (CloudCredentialTransfer, cmux-platform#587): the person's own
 * `claude setup-token` login (CLAUDE_CODE_OAUTH_TOKEN from the environment or --credentials) goes from the
 * client straight to their own machine over the machine routes, never kept by the platform. The journey runs
 * the app's own preflight and installer programs, read from CloudCredentialInstaller.swift, through the same
 * exec and fs/write routes, so a green reply proves the path a signed-in person's Cloud chat takes. Without a
 * token the step is skipped and the reply fails "Not logged in".
 *
 * --model stub makes the model endpoint the only stand-in: the shared model stub (tests/fixtures/model-stub) runs on
 * the machine's loopback
 * and Claude Code's settings point there (after the login copy, whose installer refuses a custom endpoint). The login
 * passed is a made-up setup-token shape, so no real credential exists. The reply must carry the stub's nonce, every
 * model request must carry the passed login (its SHA-256, which the stub logs: the credential hop), and one Bash tool
 * call must come back with its output. Account, machine, acpmux and the Claude Code binary are the real ones.
 *
 * --seed none|auto sets the create's seed (none: boot from the image even when the person has a machine to copy;
 * auto, the default, the server's choice). The summary and the probe row carry ready_ms, create machine to agent
 * running (create, running, first exec, login copy, start agent), when every one of those passed.
 * --probe-out FILE writes the run as one synthetic-probe result row (cmuxterm-hq probes.py: probe, at,
 * outcome ok|fail, ms = send to first reply, error), --probe NAME naming it.
 *
 * Secrets are read from the environment or files, sent only in headers or request bodies, and never printed.
 */
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { createServer } from "node:net";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const STACK_API = "https://api.stack-auth.com";
export const STACK = {
  dev: { project: "454ecd03-1db2-4050-845e-4ce5b0cd9895", clientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g" },
  prod: { project: "9790718f-14cd-4f7e-824d-eaf527a82b82", clientKey: "" },
} as const;
type StackName = keyof typeof STACK;

export type Backend = { name: string; api: string; stack: StackName };

/** The backend names this journey knows (CloudConfiguration.swift, backend/scripts/deploy-worker.sh). */
export function resolveBackend(name: string, apiOverride?: string, stackOverride?: string, localPort = 8787): Backend {
  const stack = (s: StackName): StackName => (stackOverride === "dev" || stackOverride === "prod" ? stackOverride : s);
  if (apiOverride) return { name: name || "custom", api: apiOverride.replace(/\/+$/, ""), stack: stack("dev") };
  // preview-<PR> (backend.yml) or preview-<tag> (a personal dev Worker, cloud-dev-loop.sh).
  const preview = /^preview-([a-z0-9][a-z0-9-]{0,40})$/.exec(name);
  if (preview) return { name, api: `https://cmux-api-preview-${preview[1]}.debussy.workers.dev`, stack: stack("dev") };
  switch (name) {
    case "local":
      return { name, api: `http://127.0.0.1:${localPort}`, stack: stack("dev") };
    case "dev":
    case "development":
      return { name: "dev", api: "https://cmux-api-development.debussy.workers.dev", stack: stack("dev") };
    case "staging":
      return { name, api: "https://cloud-api-staging.cmux.dev", stack: stack("dev") };
    case "prod":
    case "production":
      return { name: "prod", api: "https://cloud-api.cmux.dev", stack: stack("prod") };
    default:
      throw new Error(`--backend ${name}: one of local, dev, preview-N (or preview-TAG), staging, prod (or --api URL)`);
  }
}

/** KEY=value lines; values never leave this process. */
export function readEnvFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
    if (m) out[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, "$2");
  }
  return out;
}

export type Status = "pass" | "fail" | "skip";
export type Step = { step: string; status: Status; ms: number; detail: string };

/** Words that may never reach the log, the JSON or a PR comment, whatever an answer holds. */
const SECRET_SHAPES = [/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+/g, /\b(cmvm|cmk|cmuxvm_sk|cmm|pck|ssk)_[A-Za-z0-9_-]{8,}/g, /[Bb]earer\s+\S+/g];
export function scrub(text: string, secrets: string[] = []): string {
  let out = text;
  for (const s of secrets) if (s && s.length >= 6) out = out.split(s).join("[secret]");
  for (const re of SECRET_SHAPES) out = out.replace(re, "[secret]");
  return out;
}

/** The steps from asking for a machine to its agent running, in order (cmux#36050). */
export const READY_STEPS: readonly ((step: string) => boolean)[] = [
  (s) => s === "create machine",
  (s) => s === "running (status)",
  (s) => s === "first exec",
  (s) => s === "pass Claude login" || s === "pass Codex login",
  (s) => s.startsWith("start agent ("),
];

/** Create machine to agent running, in ms: the sum of the READY_STEPS, or null unless each one ran and passed. */
export function readyMs(steps: Step[]): number | null {
  let total = 0;
  for (const is of READY_STEPS) {
    const s = steps.find((x) => is(x.step));
    if (s?.status !== "pass") return null;
    total += s.ms;
  }
  return total;
}

export function summaryMarkdown(backend: Backend, steps: Step[], meta: Record<string, string> = {}): string {
  const failed = steps.filter((s) => s.status === "fail").length;
  const total = steps.reduce((n, s) => n + s.ms, 0);
  const ready = readyMs(steps);
  const head = `${failed ? "FAIL" : "PASS"}: Cloud journey on \`${backend.name}\` (${backend.api}), ${(total / 1000).toFixed(1)} s${ready === null ? "" : `; create machine to agent running ${(ready / 1000).toFixed(1)} s`}`;
  const extra = Object.entries(meta).map(([k, v]) => `${k}: ${v}`).join(", ");
  const rows = steps.map((s) => `| ${s.status === "pass" ? "pass" : s.status === "fail" ? "**FAIL**" : "skip"} | ${s.step} | ${s.ms} | ${s.detail.replace(/\|/g, "\\|").replace(/\n/g, " ").slice(0, 300)} |`);
  return [head, extra ? `\n${extra}` : "", "", "| result | step | ms | detail |", "|---|---|---:|---|", ...rows, ""].join("\n");
}

class Journey {
  readonly steps: Step[] = [];
  readonly secrets: string[] = [];
  constructor(readonly backend: Backend, private readonly outDir: string | null, readonly meta: Record<string, string>) {}
  async step<T>(name: string, fn: () => Promise<{ value: T; detail: string }>): Promise<T> {
    const t0 = Date.now();
    try {
      const { value, detail } = await fn();
      this.record({ step: name, status: "pass", ms: Date.now() - t0, detail });
      return value;
    } catch (error) {
      this.record({ step: name, status: "fail", ms: Date.now() - t0, detail: String((error as Error)?.message ?? error).slice(0, 600) });
      throw error;
    }
  }
  skip(name: string, why: string): void {
    this.record({ step: name, status: "skip", ms: 0, detail: why });
  }
  record(s: Step): void {
    s.detail = scrub(s.detail, this.secrets);
    this.steps.push(s);
    console.log(`${s.status.toUpperCase().padEnd(4)} ${s.step} ${s.ms} ms :: ${s.detail}`);
    this.flush();
  }
  flush(): void {
    if (!this.outDir) return;
    writeFileSync(path.join(this.outDir, "journey.json"), `${JSON.stringify({ backend: this.backend, meta: this.meta, steps: this.steps }, null, 2)}\n`);
    writeFileSync(path.join(this.outDir, "summary.md"), summaryMarkdown(this.backend, this.steps, this.meta));
  }
}

type Answer = { status: number; body: any };

async function http(method: string, url: string, body: unknown, headers: Record<string, string>, timeoutMs = 30_000): Promise<Answer> {
  const res = await fetch(url, {
    method,
    headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await res.text();
  let parsed: any;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { raw: text.slice(0, 300) };
  }
  return { status: res.status, body: parsed };
}

const short = (v: unknown) => JSON.stringify(v ?? null).slice(0, 300);

/**
 * --sign-in oidc: the GitHub Actions job's OIDC token (audience: the API origin) traded at the API's
 * POST /v1/auth/github-actions for a short Stack session of the one test account the API trusts that job
 * with (backend/apps/api/src/ci-session.ts). Both tokens are pushed to `secrets` before anything can print.
 */
export async function oidcSignIn(apiOrigin: string, env: Record<string, string | undefined>, secrets: string[], fetchJson: typeof http = http): Promise<{ token: string; user: string; expiresAt: string }> {
  const url = env.ACTIONS_ID_TOKEN_REQUEST_URL;
  const bearer = env.ACTIONS_ID_TOKEN_REQUEST_TOKEN;
  if (!url || !bearer) throw new Error("no GitHub Actions OIDC token: the job needs `permissions: id-token: write`");
  secrets.push(bearer);
  const sep = url.includes("?") ? "&" : "?";
  const gh = await fetchJson("GET", `${url}${sep}audience=${encodeURIComponent(apiOrigin)}`, undefined, { authorization: `bearer ${bearer}` });
  if (gh.status !== 200 || typeof gh.body.value !== "string") throw new Error(`GitHub OIDC token HTTP ${gh.status}`);
  secrets.push(gh.body.value);
  const r = await fetchJson("POST", `${apiOrigin}/v1/auth/github-actions`, undefined, { authorization: `Bearer ${gh.body.value}` });
  if (r.status !== 200 || typeof r.body.access_token !== "string") throw new Error(`OIDC sign-in HTTP ${r.status} ${String(r.body.error ?? "")}`);
  secrets.push(r.body.access_token);
  return { token: r.body.access_token, user: String(r.body.user ?? "?"), expiresAt: String(r.body.session_expires_at ?? "?") };
}

class Api {
  bearer = "";
  constructor(readonly origin: string, readonly team?: string) {}
  private headers(): Record<string, string> {
    return { authorization: `Bearer ${this.bearer}`, ...(this.team ? { "x-cmux-team": this.team } : {}) };
  }
  async op(op: string, params: unknown, key?: string): Promise<any> {
    const r = await http("POST", `${this.origin}/v1/ops`, { op, params, ...(key ? { idempotency_key: key } : {}) }, this.headers(), 60_000);
    if (r.status !== 200 || r.body.ok !== true) throw new Error(`${op}: HTTP ${r.status} ${short(r.body.error ?? r.body)}`);
    return r.body.value;
  }
  async read(op: string, params: unknown): Promise<any> {
    const r = await http("POST", `${this.origin}/v1/read`, { op, params }, this.headers());
    if (r.status !== 200 || (r.body.ok === false)) throw new Error(`${op}: HTTP ${r.status} ${short(r.body.error ?? r.body)}`);
    return r.body.value;
  }
  async raw(method: string, route: string, body?: unknown): Promise<Answer> {
    return http(method, `${this.origin}${route}`, body, this.headers(), 60_000);
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Test-side bounded wait on a machine field (the product never polls; this is the harness). */
async function waitMachine(api: Api, machine: string, want: (m: any) => boolean, budgetMs: number, goneOk = false): Promise<any> {
  const t0 = Date.now();
  let last: any = null;
  let lastError = "";
  while (Date.now() - t0 < budgetMs) {
    try {
      last = await api.read("cloud.machine.get", { machine });
      if (want(last)) return last;
      // A machine that failed never gets there: say why now instead of waiting the budget out.
      if (last?.status === "failed") throw new Error(`machine failed: ${short({ error: last.error ?? last.failure ?? last.reason ?? last.status_reason, provider: last.provider, op: last.last_op ?? last.op })} (full row: ${short(last)})`);
    } catch (error) {
      if (String((error as Error).message).startsWith("machine failed:")) throw error;
      if (goneOk && /HTTP 404|not[ _.-]?found/i.test(String((error as Error).message))) return null;
      lastError = String((error as Error).message);
    }
    await sleep(1000);
  }
  throw new Error(`timed out after ${budgetMs} ms; last status ${last?.status} host ${last?.host}${lastError ? `; last error ${lastError}` : ""}`);
}

/** ES256 over the UTF-8 message, base64url raw r||s (host-agent.ts signMessage). */
async function sign(key: CryptoKey, message: string): Promise<string> {
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(message)));
  return Buffer.from(sig).toString("base64url");
}

type ExecResult = { code: number; stdout: string; stderr: string };
type Exec = (command: string, timeoutMs?: number) => Promise<ExecResult>;

/** The CLI's exec (cloud_client_session.rs): mint a client session, then the provider's exec-await. */
function directExec(api: Api, machine: string, journey: Journey): Exec {
  let session: { token: string; vm_id: string; linux_user: string; api_base_url: string; expires_at: number } | null = null;
  let guestRoute = false;
  const guestExec: Exec = async (command, timeoutMs = 60_000) => {
    // A VM API machine has no client sessions: the machine exec route (MachineGuest.ts) runs it instead.
    const g = await api.raw("POST", `/v1/cloud/machines/${machine}/exec`, { command, timeoutMs: Math.min(timeoutMs, 300_000) });
    const v: any = g.body?.value ?? g.body;
    if (g.status < 200 || g.status >= 300 || v?.ok === false) throw new Error(`exec: HTTP ${g.status} ${short(v?.error?.code ?? v?.error ?? v)}`);
    return { code: Number(v.exitCode ?? v.exit_code ?? 1), stdout: String(v.stdout ?? ""), stderr: String(v.stderr ?? "") };
  };
  return async (command, timeoutMs = 60_000) => {
    if (guestRoute) return guestExec(command, timeoutMs);
    if (!session || session.expires_at - Date.now() < 60_000) {
      const r = await api.raw("POST", `/v1/cloud/machines/${machine}/client-session`, { ttl_seconds: 900 });
      if (r.status === 501 && String(r.body?.error?.code ?? "") === "cloud.provider.unsupported") {
        guestRoute = true;
        return guestExec(command, timeoutMs);
      }
      if (r.status !== 200 || r.body.ok !== true) throw new Error(`client-session: HTTP ${r.status} ${short(r.body.error?.code ?? r.body.error ?? r.body)}`);
      session = r.body.value;
      journey.secrets.push(session!.token);
    }
    const s = session!;
    const r = await http("POST", `${s.api_base_url.replace(/\/+$/, "")}/v5/vms/${s.vm_id}/exec-await`, { command, linuxUser: s.linux_user, timeoutMs }, { "x-freestyle-identity-access-token": s.token }, timeoutMs + 15_000);
    if (r.status < 200 || r.status >= 300) throw new Error(`exec-await: HTTP ${r.status}`);
    const rawCode = r.body.statusCode ?? r.body.exitCode ?? r.body.code;
    // Freestyle leaves statusCode null or missing when the command timed out; the cmux CLI maps that to 124.
    return { code: rawCode === null || rawCode === undefined ? 124 : Number(rawCode), stdout: String(r.body.stdout ?? ""), stderr: String(r.body.stderr ?? "") };
  };
}

/** `cmux machine access exec` with the same credential: the journey drives the real CLI, which takes the
 * machine exec route itself on a machine whose provider has no client sessions (a VM API machine). */
function cliExec(cmux: string, api: Api, machine: string): Exec {
  return async (command, timeoutMs = 60_000) => {
    const env = { ...process.env, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer };
    const args = ["--json", "machine", "access", "exec", "--target", `machine:${machine}`, "--timeout-ms", String(Math.min(timeoutMs, 300_000)), ...(api.team ? ["--team", api.team] : []), "--", command];
    const done = spawnSync(cmux, args, { env, encoding: "utf8", timeout: timeoutMs + 30_000 });
    if (done.error) throw new Error(`${cmux}: ${done.error.message}`);
    try {
      const result = JSON.parse(done.stdout ?? "");
      if (Number.isInteger(result?.exit_code)) {
        return { code: Number(result.exit_code), stdout: String(result.stdout ?? ""), stderr: String(result.stderr ?? "") };
      }
    } catch {
      // Preserve the raw CLI answer below when it did not produce its JSON contract.
    }
    return { code: done.status ?? 1, stdout: done.stdout ?? "", stderr: done.stderr ?? "" };
  };
}

type HeadlessLink = { stateDir: string; linkSocket: string; bridgeSocket: string; close: () => Promise<void> };

/** Start the userspace link and bridge its stdio dial into a Unix socket for link sync. */
async function startHeadlessLink(cmux: string, host: string, install: { id: string; token: string }, api: string, tag: string): Promise<HeadlessLink> {
  const stateDir = mkdtempSync(path.join(tmpdir(), `cmux-journey-link-${tag}-`));
  const ensured = spawnSync(cmux, ["link", "ensure", "--state-dir", stateDir, "--install", install.id, "--port", "0"], {
    env: { ...process.env, CMUX_CLOUD_API_URL: api, CMUX_CLOUD_INSTALL_TOKEN: install.token }, encoding: "utf8", timeout: 30_000,
  });
  if (ensured.error || ensured.status !== 0) throw new Error(`link ensure failed: ${ensured.stderr || ensured.stdout || ensured.error?.message}`);
  let ready: any;
  for (const line of ensured.stdout.split("\n").reverse()) {
    try { const value = JSON.parse(line); if (value.socket) { ready = value; break; } } catch { /* status output */ }
  }
  if (!ready?.socket) throw new Error(`link ensure returned no socket: ${ensured.stdout.slice(-300)}`);
  const bridgeSocket = path.join(stateDir, "machine.sock");
  const server = createServer((socket) => {
    const child = spawn(cmux, ["link", "dial", "--host", host, "--service", "daemon", "--socket", ready.socket], { stdio: ["pipe", "pipe", "pipe"] });
    socket.pipe(child.stdin);
    child.stdout.pipe(socket);
    child.stderr.resume();
    const close = () => { if (!socket.destroyed) socket.destroy(); if (!child.killed) child.kill(); };
    socket.on("close", close);
    child.on("exit", () => { if (!socket.destroyed) socket.destroy(); });
  });
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(bridgeSocket, () => resolve()); });
  return {
    stateDir, linkSocket: ready.socket, bridgeSocket,
    close: async () => {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      const stopped = spawnSync(cmux, ["link", "stop", "--state-dir", stateDir], { encoding: "utf8", timeout: 20_000 });
      if (stopped.error) throw stopped.error;
      rmSync(stateDir, { recursive: true, force: true });
    },
  };
}

/**
 * The run as one synthetic-probe result row (cmuxterm-hq tools/fleet-reconcilers/probes.py): ok only when a reply
 * was read back, with ms from the send to the first reply; otherwise fail with the first failed step.
 */
export function probeRow(probe: string, steps: Step[], run?: string, at = new Date()): Record<string, unknown> {
  const send = steps.find((s) => s.step === "send chat");
  const reply = steps.find((s) => s.step === "reply");
  const failed = steps.find((s) => s.status === "fail");
  const ready = readyMs(steps);
  const base = { probe, at: at.toISOString().replace(/\.\d+Z$/, "Z"), runner: "github-actions", ...(run ? { run } : {}), ...(ready === null ? {} : { ready_ms: ready }) };
  if (reply?.status === "pass" && send) return { ...base, outcome: "ok", ms: send.ms + reply.ms };
  return { ...base, outcome: "fail", error: failed ? `${failed.step}: ${failed.detail}`.slice(0, 300) : "no reply step ran" };
}

/** A Swift `static let NAME = #"""...."""#` raw string, with the closing delimiter's indentation stripped. */
export function swiftRawString(source: string, name: string): string {
  const m = new RegExp(`static let ${name} = #"""\\n([\\s\\S]*?)\\n([ \\t]*)"""#`).exec(source);
  if (!m) throw new Error(`no ${name} in the installer source`);
  const indent = m[2];
  return m[1].split("\n").map((line) => (line.startsWith(indent) ? line.slice(indent.length) : line.trimStart())).join("\n");
}

/** The model stub --model stub runs on the machine. */
/** The shared model stub (tests/fixtures/model-stub, #35332): Anthropic Messages and OpenAI Responses, scripted. */
export const MODEL_STUB_PY = fileURLToPath(new URL("../../tests/fixtures/model-stub/model_stub.py", import.meta.url));
/**
 * The journey's stub script: one Bash call whose output (printf joins it, so neither the command nor an error that
 * quotes it carries it) the reply then repeats, so the reply shows the tool round trip.
 */
export const JOURNEY_STUB_SCRIPT = { version: 1, steps: [{ shell: "printf '%s-%s\\n' {{nonce}} tool" }, { text: "Stub reply {{nonce}}. The tool printed {{result.0}}." }] };

/** The Mac's installer (CloudCredentialInstaller.swift), relative to this script in a cmux checkout. */
export const INSTALLER_SWIFT = fileURLToPath(new URL("../../Packages/macOS/CmuxNext/Sources/CmuxNextCloudCredentials/CloudCredentialInstaller.swift", import.meta.url));

/** CloudCredentialInstaller.preflight and .command(provider: .claude, payloadPath:), built as the Swift builds them. */
/**
 * The Mac's login copy programs. `creatorTeamGuest` is the DEV and dogfood creator allowance (nightly builds,
 * CloudCredentialTransfer.allowsCreatorTeamGuest): the machine's creator may also copy a login to a team guest.
 */
export function claudeLoginPrograms(installerSwift: string, creatorTeamGuest = false): { preflight: string; install: (payloadPath: string) => string } {
  return loginPrograms(installerSwift, "claude", creatorTeamGuest);
}

/** The same programs for either provider CloudCredentialTransfer copies (claude or codex). */
export function loginPrograms(installerSwift: string, provider: "claude" | "codex", creatorTeamGuest = false): { preflight: string; install: (payloadPath: string) => string } {
  const preflight = swiftRawString(installerSwift, creatorTeamGuest ? "creatorTeamPreflight" : "preflight");
  const script = swiftRawString(installerSwift, "script");
  return {
    preflight,
    install: (payloadPath) =>
      "set -e\n. /etc/cmux/agent-auth.sh\ncmux_agent_drop_model_plane_env\n" +
      `python3 - ${shq(provider)} ${shq(payloadPath)} ${creatorTeamGuest ? "owner,team" : "owner"} <<'CMUX_CREDENTIAL_INSTALL'\n${script}\nCMUX_CREDENTIAL_INSTALL`,
  };
}

/** What the preflight checks, one by one, for a refusal's message: the kind record, the image's launchers, the exec user. */
export const PREFLIGHT_PROBE =
  `printf 'vm-kind=%s agent-auth.sh=%s user=%s' "$(head -c 64 /etc/cmux/vm-kind 2>/dev/null | tr -d '[:space:]')" ` +
  `"$([ -f /etc/cmux/agent-auth.sh ] && echo yes || echo no)" "$(id -un)"`;

/**
 * Run the preflight until it passes or `budgetMs` runs out. On a VM API machine nothing writes /etc/cmux/vm-kind
 * at create: the guest's cmux-host writes it once it is bound (record_owner_kind), which can land after the
 * machine reads running and takes its first exec. A refusal that outlasts the budget names the failing check.
 */
export async function waitPreflight(exec: Exec, program: string, kinds: string, budgetMs = 90_000, pauseMs = 3_000, pause = sleep): Promise<{ waitedMs: number; tries: number }> {
  const t0 = Date.now();
  for (let tries = 1; ; tries++) {
    const pre = await exec(program);
    if (pre.code === 0) return { waitedMs: Date.now() - t0, tries };
    if (Date.now() - t0 + pauseMs >= budgetMs) {
      const seen = await exec(PREFLIGHT_PROBE).then((r) => r.stdout.trim(), (error) => `probe failed: ${(error as Error).message}`);
      throw new Error(`preflight exit ${pre.code} after ${tries} tries in ${Math.round((Date.now() - t0) / 1000)} s: not an ${kinds} machine with the image's launchers (${seen})`);
    }
    await pause(pauseMs);
  }
}

/** CloudCredentialTransfer.validate: what the app accepts as a login to copy, per provider. */
export function validLogin(provider: "claude" | "codex", value: string): boolean {
  if (Buffer.byteLength(value) > 12_000) return false;
  if (provider === "claude") return /^sk-ant-oat01-[\x21-\x7e]{19,11987}$/.test(value);
  try {
    const auth = JSON.parse(value);
    const tokens = auth?.tokens;
    return (auth.OPENAI_API_KEY == null) && !!tokens && ["access_token", "refresh_token", "id_token"].every((k) => typeof tokens[k] === "string" && tokens[k].length > 0);
  } catch {
    return false;
  }
}

/**
 * A made-up Codex ChatGPT sign-in (auth.json) for --model stub: unsigned JWTs whose claims Codex reads (plan, account,
 * an expiry far ahead) and a fresh last_refresh, so Codex never tries to refresh it against OpenAI.
 */
export function stubCodexAuth(seed = randomBytes(16).toString("hex"), now = new Date()): string {
  const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const exp = Math.floor(now.getTime() / 1000) + 30 * 86400;
  const claims = { email: "journey-stub@cmux.invalid", exp, "https://api.openai.com/auth": { chatgpt_plan_type: "pro", chatgpt_account_id: "acct_journeystub", chatgpt_user_id: `user_${seed.slice(0, 8)}` } };
  const jwt = (extra: object) => `${b64({ alg: "none", typ: "JWT" })}.${b64({ ...claims, ...extra })}.journeystub`;
  return JSON.stringify({ OPENAI_API_KEY: null, tokens: { id_token: jwt({}), access_token: jwt({ jti: `journeystub-${seed}` }), refresh_token: `journeystub-refresh-${seed}`, account_id: "acct_journeystub" }, last_refresh: now.toISOString() });
}

/**
 * --model stub, Codex: the Python program (argv: the stub's port, then config.toml, by default the work user's) that
 * points Codex at the stub. A model provider on the stub's /v1 that uses the ChatGPT sign-in, and:
 * - model "stub-model": a catalog model (the default) gets Code Mode, one JavaScript exec tool sent as an
 *   additional_tools input item the stub cannot answer; a model Codex does not know gets the plain exec_command tool;
 * - chatgpt_base_url on the stub, the apps, plugins and remote_plugin features off and analytics off, so the made-up
 *   sign-in never reaches chatgpt.com (whose 401s would also send Codex to refresh it at auth.openai.com).
 * An active profile's model and provider would win over these, so the root profile key goes (the [profiles.*] tables
 * stay). The image's other settings stay. TOML refuses a table defined twice, so the keys go into the [features] and
 * [analytics] tables the file already has, and a second run replaces its own provider table.
 */
export const CODEX_STUB_CONFIG = String.raw`import pathlib, re, sys
port = sys.argv[1]
p = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else '/home/cmux/.codex/config.toml')
lines = p.read_text().splitlines() if p.exists() else []
header = re.compile(r'\s*\[\s*([^\]]+?)\s*\]\s*(#.*)?$')
tables = {'features': {'apps': 'false', 'plugins': 'false', 'remote_plugin': 'false'}, 'analytics': {'enabled': 'false'}}
root = {'model': '"stub-model"', 'model_provider': '"journeystub"', 'chatgpt_base_url': '"http://127.0.0.1:' + port + '/backend-api/"'}
def assigns(line, keys):
    m = re.match(r'\s*([A-Za-z0-9_-]+)\s*=', line)
    return bool(m) and m.group(1) in keys
out, table, seen = [], None, set()
for line in lines:
    m = header.match(line)
    if m:
        table = m.group(1)
        if table == 'model_providers.journeystub':
            continue
        out.append(line)
        if table in tables and table not in seen:
            seen.add(table)
            out += [k + ' = ' + v for k, v in tables[table].items()]
        continue
    if table == 'model_providers.journeystub' or assigns(line, {**root, 'profile': ''} if table is None else tables.get(table, {})):
        continue
    out.append(line)
out = [k + ' = ' + v for k, v in root.items()] + out
for name in tables:
    if name not in seen:
        out += ['', '[' + name + ']'] + [k + ' = ' + v for k, v in tables[name].items()]
out += ['', '[model_providers.journeystub]', 'name = "journey stub"', 'base_url = "http://127.0.0.1:' + port + '/v1"',
        'wire_api = "responses"', 'requires_openai_auth = true']
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text('\n'.join(out) + '\n')
print('stub-ready')`;

/** The bearer a harness sends the model endpoint for a copied login: Claude's token, Codex's ChatGPT access token. */
export function loginBearer(provider: "claude" | "codex", value: string): string {
  return provider === "codex" ? (JSON.parse(value).tokens.access_token as string) : value;
}

/** The guest's own cmux-tui (cloud_start_chat.rs GUEST_PRELUDE): the build the machine's acpmux runs. */
const GUEST = 'export HOME="${HOME:-/home/cmux}"; cd "$HOME" 2>/dev/null || cd /; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ';
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

/** --machine: stop an earlier run's model stub and drop its endpoint from Claude Code's settings (and Codex's stub provider). */
export const REUSE_RESET =
  `pkill -u "$(id -u)" -f '[j]ourney-model-stub.py' || true; rm -f /home/cmux/.cmux/journey-model-stub.*; ` +
  `python3 - <<'PY'\nimport json, pathlib\np = pathlib.Path('/home/cmux/.claude/settings.json')\nif p.exists() and not p.is_symlink():\n    c = json.loads(p.read_text())\n    if c.get('env', {}).pop('ANTHROPIC_BASE_URL', None) is not None:\n        p.write_text(json.dumps(c)); print('dropped the stub endpoint')\nPY`;

/** How long --keyed-start waits after the start before it reads the daemon again (over acpmux.service's RestartSec=3). */
export const KEYED_SETTLE_MS = 8_000;

/**
 * The app's keyed acpmux start (cmux-platform AcpmuxRoute.ts): a fresh one-run key K, 64 lowercase hex and a newline,
 * as the octet-stream body. K is a throwaway made here and pushed to `secrets` before anything can print.
 */
async function keyedAcpmuxStart(api: Api, machine: string, secrets: string[]): Promise<{ ok: true; personInstance: string } | { ok: false; detail: string }> {
  const key = randomBytes(32).toString("hex");
  secrets.push(key);
  const res = await fetch(`${api.origin}/v1/cloud/machines/${machine}/acpmux/keyed-start`, {
    method: "POST",
    headers: { authorization: `Bearer ${api.bearer}`, "content-type": "application/octet-stream", ...(api.team ? { "x-cmux-team": api.team } : {}) },
    body: `${key}\n`,
    signal: AbortSignal.timeout(120_000),
  });
  const body: any = await res.json().catch(() => ({}));
  const instance = body?.value?.personInstance ?? body?.personInstance;
  if (res.status !== 200 || typeof instance !== "string") return { ok: false, detail: `HTTP ${res.status} ${short(body?.error ?? body)}` };
  return { ok: true, personInstance: instance };
}

/** Why the daemon `acp --json daemon status` describes is not the keyed one the start made, or null. */
export function keyedHoldProblem(personInstance: string, status: any): string | null {
  if (!status || status.running === false || status.pid === undefined) return `no daemon serves after the keyed start: ${short(status)}`;
  if (status.personKey !== true) return `an unkeyed daemon took the socket after the keyed start (acpmux.service restarted and took over): ${short(status)}`;
  if (status.personInstance !== undefined && status.personInstance !== personInstance) return `another keyed daemon (${String(status.personInstance)}) serves, not the one this start made (${personInstance})`;
  return null;
}

/** The ids of `cloud list-machines --json` rows that are not deleted. */
export function machineIds(rows: any[]): string[] {
  return rows.filter((m) => m && m.status !== "deleted").map((m) => String(m.id ?? m.machine_id ?? "")).filter(Boolean);
}

/** The ids in `after` that `before` lacks. */
export function newMachineIds(before: string[], after: string[]): string[] {
  const seen = new Set(before);
  return [...new Set(after.filter((id) => !seen.has(id)))];
}

/**
 * --app-cli PATH: the commands a person runs, through a NEXT build's own CLI (cmux#35086). The `cloud`
 * verbs go to that app's control socket (--socket PATH or CMUX_SOCKET_PATH), so the app must be running
 * and signed in; its build decides the backend, which each step names from the answer when it says.
 */
async function appCliJourney(cli: string, socket: string | undefined, J: Journey, agent: string, prompt: string): Promise<void> {
  const env = { ...process.env, ...(socket ? { CMUX_SOCKET_PATH: socket } : {}) };
  const run = (words: string[], timeoutMs = 120_000) => {
    const done = spawnSync(cli, words, { env, encoding: "utf8", timeout: timeoutMs });
    if (done.error) throw new Error(`${cli} ${words.slice(0, 2).join(" ")}: ${done.error.message}`);
    let json: any = {};
    try {
      json = JSON.parse(done.stdout || "{}");
      json = json?.result ?? json;
    } catch {
      json = {};
    }
    return { code: done.status ?? 1, stdout: done.stdout ?? "", stderr: done.stderr ?? "", json };
  };
  const must = (name: string, r: ReturnType<typeof run>) => {
    if (r.code !== 0) throw new Error(`\`cmux ${name}\` exit ${r.code}: ${(r.stderr || r.stdout).trim().slice(-400)}`);
    return r;
  };
  const where = (j: any) => j?.api_base_url ?? j?.backend ?? j?.api ?? j?.origin ?? j?.host ?? "app";
  // The backend refuses a create with a name ("can't create a machine with a size, idle pause, name or
  // bootstrap yet"), so the create takes no flags, and a `pending` answer (no id) names nothing this run
  // could match. Only the id the create answered is ever deleted; after a `pending` answer the machines
  // that appeared since the create are named for a person to check, never deleted (another create in the
  // same account may be one of them).
  // null when the list could not be read (exit code, or the app's list not loaded yet): never diffed as empty.
  const listIds = (): string[] | null => {
    const r = run(["cloud", "list-machines", "--json"], 60_000);
    if (r.code !== 0 || r.json?.loaded === false) return null;
    return machineIds(r.json?.machines ?? r.json?.items ?? (Array.isArray(r.json) ? r.json : []));
  };
  let before: string[] | null = null;
  let createRan = false;
  let machine: string | null = null;
  try {
    await J.step("app cli: signed in (cloud list-machines)", async () => {
      const r = must("cloud list-machines", run(["cloud", "list-machines", "--json"], 60_000));
      if (r.json?.account?.signed_in !== true) throw new Error("the app is not signed in (account.signed_in is not true)");
      return { value: null, detail: `${(r.json.machines ?? []).length} machines; ${where(r.json.account)}` };
    });
    await J.step("app cli: vm token create", async () => {
      const r = must("vm token create", run(["vm", "token", "create", "--ttl", "30m", "--json"], 60_000));
      return { value: null, detail: `issuer ${where(r.json)}` };
    });
    machine = await J.step("app cli: cloud new-machine", async () => {
      before = listIds();
      createRan = true;
      const r = must("cloud new-machine", run(["cloud", "new-machine", "--json"], 600_000));
      const id = r.json?.machine_id ?? r.json?.machine?.id ?? r.json?.id;
      if (!id) throw new Error(`no machine id in ${short(r.json)}${r.json?.status === "creating" ? " (pending: the create goes on; this run deletes nothing it did not get an id for)" : ""}`);
      return { value: String(id), detail: `${id} via ${where(r.json)}` };
    });
    const target = `machine:${machine}`;
    await J.step("app cli: cloud machine-status", async () => {
      const r = must("cloud machine-status", run(["cloud", "machine-status", "--target", target, "--json"], 60_000));
      const id = r.json?.machine_id ?? r.json?.machine?.id ?? r.json?.id;
      if (id && id !== machine) throw new Error(`answered for ${id}, not ${machine}`);
      return { value: null, detail: `status ${r.json?.status ?? r.json?.machine?.status ?? "?"} via ${where(r.json)}` };
    });
    await J.step("app cli: cloud exec", async () => {
      const r = must("cloud exec", run(["cloud", "exec", "--target", target, "--command", "echo ok", "--json"], 120_000));
      if (!/\bok\b/.test(r.stdout)) throw new Error(`no ok in ${r.stdout.slice(-200)}`);
      return { value: null, detail: "ok" };
    });
    await J.step("app cli: cloud start-session", async () => {
      const r = must("cloud start-session", run(["cloud", "start-session", "--target", target, "--agent", agent, "--json"], 600_000));
      return { value: null, detail: `session ${r.json?.session_id ?? "?"}` };
    });
    await J.step("app cli: cloud start-chat --wait", async () => {
      const r = must("cloud start-chat", run(["cloud", "start-chat", "--target", target, "--prompt", prompt, "--agent", agent, "--wait", "--timeout", "600", "--json"], 700_000));
      const reply = String(r.json?.reply ?? "");
      if (!reply.trim()) throw new Error(`no reply in ${short(r.json)}`);
      return { value: null, detail: reply.slice(0, 280) };
    });
  } finally {
    if (!machine && createRan) {
      const prior = before as string[] | null; // set inside the create step's closure
      await J.step("app cli: no machine id to delete", async () => {
        const after = listIds();
        if (!prior || !after) throw new Error(`the machine list could not be read ${prior ? "after" : "before"} the create; check the account's machines by hand`);
        const fresh = newMachineIds(prior, after);
        throw new Error(fresh.length
          ? `machines new since the create, not deleted (another create may own one): ${fresh.join(", ")}`
          : "no machine is new since the create");
      }).catch(() => undefined);
    }
    if (machine) {
      const id = machine;
      await J.step("app cli: cloud kill-machine", async () => {
        must("cloud kill-machine", run(["cloud", "kill-machine", "--target", `machine:${id}`, "--confirm", "--json"], 120_000));
        return { value: null, detail: id };
      }).catch(() => undefined);
    }
  }
}

/** The link_token refusals that mean "this install has no Native device enrollment" (cloud-native-dial.ts details.reason). */
const NATIVE_ENROLLMENT_REASONS = new Set(["host_missing", "host_unconfirmed", "proof_missing"]);

/**
 * The skip reason when a link_token answer refused only for want of a Native device proof (an app-only
 * enrollment), else null: every other answer, an older backend's refusal with no reason included, is the step's own.
 */
export function nativeProofSkip(body: any): string | null {
  const error = body?.ok === false ? body.error : null;
  const reason = error?.details?.reason;
  if (error?.code !== "auth.forbidden" || typeof reason !== "string" || !NATIVE_ENROLLMENT_REASONS.has(reason)) return null;
  return `needs a Native device proof (app-only): link_token refused ${reason}; this journey's cli install has no Native device enrollment`;
}

/**
 * Steps that passed on the version before a deploy and fail after it: the deploy's own reds. A step that
 * was already red before (a known backend bug) is not the deploy's fault and never triggers a rollback.
 * With no baseline (the first run, or it could not sign in), every failed step counts.
 */
export function newReds(before: Step[] | null, after: Step[]): Step[] {
  const passed = new Set((before ?? []).filter((s) => s.status === "pass").map((s) => s.step));
  return after.filter((s) => s.status === "fail" && (before === null || passed.has(s.step)));
}

function argValue(flag: string, argv: string[]): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("*/")[0]);
    return 0;
  }
  // --compare BEFORE.json AFTER.json: exit 3 when the deploy made a step red (newReds), 0 otherwise.
  const compare = argv.indexOf("--compare");
  if (compare >= 0) {
    const load = (f: string | undefined): Step[] | null => {
      try { return f ? (JSON.parse(readFileSync(f, "utf8")).steps as Step[]) : null; } catch { return null; }
    };
    const before = load(argv[compare + 1]);
    const after = load(argv[compare + 2]) ?? [];
    const reds = newReds(before, after);
    for (const r of reds) console.log(`NEW RED ${r.step}: ${r.detail.slice(0, 300)}`);
    console.log(reds.length ? `${reds.length} step(s) red after the deploy that were green before it` : "no new reds");
    return reds.length ? 3 : 0;
  }
  const backend = resolveBackend(argValue("--backend", argv) ?? (argValue("--api", argv) ? "custom" : "staging"), argValue("--api", argv), argValue("--stack", argv), Number(argValue("--local-port", argv) ?? 8787));
  const outArg = argValue("--out", argv);
  const outDir = outArg ? path.resolve(outArg) : null;
  if (outDir) mkdirSync(outDir, { recursive: true });
  const credFile = argValue("--credentials", argv);
  const creds: Record<string, string> = { ...(credFile ? readEnvFile(readFileSync(credFile, "utf8")) : {}) };
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL ?? creds.CMUX_DOGFOOD_STACK_EMAIL ?? creds.CMUX_UITEST_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD ?? creds.CMUX_DOGFOOD_STACK_PASSWORD ?? creds.CMUX_UITEST_STACK_PASSWORD;
  const team = argValue("--team", argv) ?? process.env.CMUX_JOURNEY_TEAM ?? undefined;
  const signIn = argValue("--sign-in", argv) ?? "password";
  if (signIn !== "password" && signIn !== "oidc") throw new Error(`--sign-in ${signIn}: password or oidc`);
  const agent = argValue("--agent", argv) ?? "claude";
  const prompt = argValue("--prompt", argv) ?? "Reply with one short sentence that names the planet you are on.";
  const chatBudget = Number(argValue("--chat-timeout", argv) ?? 300) * 1000;
  const cmux = argValue("--cmux", argv);
  // --machine ID: run on that existing machine and keep it (no create, pause, resume or delete).
  const reuse = argValue("--machine", argv);
  const keyedStart = argv.includes("--keyed-start");
  const keep = argv.includes("--keep") || Boolean(reuse);
  const seed = argValue("--seed", argv) ?? "auto";
  if (seed !== "none" && seed !== "auto") throw new Error(`--seed ${seed}: none or auto`);
  const only = new Set((argValue("--skip", argv) ?? "").split(",").filter(Boolean));
  if (reuse) only.add("pause");
  // --model stub: the model endpoint is the only stand-in (the shared model stub on the machine). The login the
  // journey passes is then a made-up setup-token shape: the stub checks it arrived, and no real credential exists.
  const modelStub = argValue("--model", argv) === "stub";
  const nonce = randomBytes(6).toString("hex");
  const claudeLogin = modelStub
    ? `sk-ant-oat01-journeystub-${randomBytes(24).toString("hex")}`
    : (process.env.CLAUDE_CODE_OAUTH_TOKEN || creds.CLAUDE_CODE_OAUTH_TOKEN || "").trim();
  // Codex's login is its auth.json (a ChatGPT sign-in), as the app copies it; CODEX_AUTH_JSON for a real run.
  const codexLogin = modelStub ? stubCodexAuth() : (process.env.CODEX_AUTH_JSON || creds.CODEX_AUTH_JSON || "").trim();
  const provider: "claude" | "codex" | undefined = agent === "claude" || agent === "codex" ? agent : undefined;
  const login = provider === "codex" ? codexLogin : provider === "claude" ? claudeLogin : "";
  const loginStep = provider === "codex" ? "pass Codex login" : "pass Claude login";
  const probeOut = argValue("--probe-out", argv);
  const probeName = argValue("--probe", argv) ?? `cloud-chat-replies-${backend.name === "prod" ? "production" : backend.name}`;
  const tag = `jr-${Date.now().toString(36)}`;
  const J = new Journey(backend, outDir, { tag, team: team ?? "(personal)", agent, exec: cmux ? `cmux CLI ${cmux}` : "client session", model: modelStub ? "stub (on the machine)" : "real" });
  if (password) J.secrets.push(password);
  if (claudeLogin) J.secrets.push(claudeLogin);
  if (codexLogin) {
    J.secrets.push(codexLogin);
    try {
      const t = JSON.parse(codexLogin).tokens ?? {};
      for (const k of ["access_token", "refresh_token", "id_token"]) if (typeof t[k] === "string" && t[k]) J.secrets.push(t[k]);
    } catch { /* validLogin names a malformed login */ }
  }
  const appCli = argValue("--app-cli", argv);
  if (appCli) {
    J.meta.exec = `app CLI ${appCli}`;
    await appCliJourney(appCli, argValue("--socket", argv), J, agent, prompt).catch(() => undefined);
    const failedApp = J.steps.filter((s) => s.status === "fail").length;
    console.log(`\n${failedApp ? "FAIL" : "PASS"} app CLI journey: ${J.steps.length - failedApp} passed, ${failedApp} failed`);
    return failedApp ? 1 : 0;
  }
  const api = new Api(backend.api, team);
  let machine: string | null = null;
  let deleted = false;
  let cleaned = false;
  let headlessLink: HeadlessLink | null = null;
  // Delete what this run made, pass, fail or cancel. A create whose reply was lost leaves `machine`
  // null, so the run's own machine is also found by its name (`cloud journey <tag>`).
  const cleanup = async () => {
    if (headlessLink) {
      await headlessLink.close().catch(() => undefined);
      headlessLink = null;
    }
    if (cleaned || keep || deleted || !api.bearer) return;
    cleaned = true;
    let id = machine;
    if (!id) {
      const v = await api.read("cloud.machine.list", {}).catch(() => null);
      const rows: any[] = v?.machines ?? v?.items ?? (Array.isArray(v) ? v : []);
      id = rows.find((r) => r?.name === `cloud journey ${tag}` && r.status !== "deleted")?.id ?? null;
    }
    if (!id) return;
    const target: string = id;
    await J.step("delete (cleanup)", async () => {
      await api.op("cloud.machine.delete", { machine: target }, `${tag}-cleanup-delete`);
      return { value: null, detail: target };
    }).catch(() => undefined);
  };
  // The cmuxterm-hq probes.py row: ok with send-to-reply ms, or fail naming the first failed step (or none reached).
  const writeProbe = () => {
    if (probeOut) writeFileSync(probeOut, `${JSON.stringify(probeRow(probeName, J.steps, process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : undefined))}\n`);
  };
  // A job cancel or timeout sends SIGTERM, which skips `finally`: clean up, write results, exit.
  const onSignal = (signal: string) => {
    void cleanup().finally(() => {
      J.flush();
      writeProbe();
      process.exit(signal === "SIGINT" ? 130 : 143);
    });
  };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  try {
    await J.step("health", async () => {
      const r = await http("GET", `${backend.api}/v1/health`, undefined, {});
      if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body)}`);
      return { value: null, detail: `commit ${r.body.commit ?? r.body.version ?? "?"}` };
    });
    if (signIn === "oidc") {
      api.bearer = await J.step("sign in (agent test account)", async () => {
        const s = await oidcSignIn(backend.api, process.env, J.secrets);
        return { value: s.token, detail: `GitHub OIDC, user ${s.user}, session ends ${s.expiresAt}` };
      });
    } else if (!email || !password) {
      await J.step("sign in (agent test account)", async () => {
        throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
      });
    }
    const stack = STACK[backend.stack];
    if (signIn === "password") api.bearer = await J.step("sign in (agent test account)", async () => {
      const r = await http("POST", `${STACK_API}/api/v1/auth/password/sign-in`, { email, password }, {
        "x-stack-access-type": "client",
        "x-stack-project-id": stack.project,
        ...(stack.clientKey ? { "x-stack-publishable-client-key": stack.clientKey } : {}),
      });
      if (r.status !== 200 || typeof r.body.access_token !== "string") throw new Error(`Stack sign-in HTTP ${r.status} ${String(r.body.code ?? "")}`);
      J.secrets.push(r.body.access_token, r.body.refresh_token ?? "");
      return { value: r.body.access_token as string, detail: `Stack project ${stack.project.slice(0, 8)}` };
    });
    const user = await J.step("user.ensure", async () => {
      const v = await api.op("user.ensure", {}, `${tag}-ensure`);
      return { value: v, detail: `user ${v.id ?? v.user?.id ?? "?"}` };
    });
    const install = await J.step("install token", async () => {
      const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
      const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
      const inst = await api.op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: `cloud journey ${tag}`, device_name: "cloud journey", platform: "linux" }, `${tag}-install`);
      const userId = inst.user ?? user.id ?? user.user?.id;
      const ch = await http("POST", `${backend.api}/v1/auth/challenge`, { user: userId, install: inst.id }, {});
      if (ch.status !== 200) throw new Error(`challenge HTTP ${ch.status} ${short(ch.body)}`);
      const tok = await http("POST", `${backend.api}/v1/auth/token`, { user: userId, install: inst.id, nonce: ch.body.nonce, signature: await sign(pair.privateKey, `${ch.body.message_prefix}${ch.body.nonce}`) }, {});
      if (tok.status !== 200 || typeof tok.body.access_token !== "string") throw new Error(`token HTTP ${tok.status} ${short(tok.body)}`);
      J.secrets.push(tok.body.access_token);
      return { value: { id: inst.id as string, token: tok.body.access_token as string }, detail: `install ${inst.id}` };
    });
    const installApi = new Api(backend.api, team);
    installApi.bearer = install.token;

    const created = reuse
      ? await J.step("use machine", async () => {
          const m = await api.read("cloud.machine.get", { machine: reuse });
          if (m.status === "paused") await api.op("cloud.machine.start", { machine: reuse }, `${tag}-wake`);
          return { value: m, detail: `${reuse} status ${m.status}${m.status === "paused" ? " (started)" : ""}, kept` };
        })
      : await J.step("create machine", async () => {
          const v = await api.op("cloud.machine.create", { name: `cloud journey ${tag}`, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 }, ...(seed === "none" ? { seed: "none" } : {}) }, `${tag}-create`);
          machine = v.machine.id as string;
          return { value: v.machine, detail: `${machine} status ${v.machine.status}` };
        });
    const bound = await J.step("running (status)", async () => {
      const m = await waitMachine(api, created.id, (x) => x.status === "running" && Boolean(x.host), 300_000);
      return { value: m, detail: `host ${m.host}, daemon ${m.image?.daemon_version ?? "?"}` };
    });
    await J.step("listed", async () => {
      const v = await api.read("cloud.machine.list", {});
      const rows: any[] = v.machines ?? v.items ?? (Array.isArray(v) ? v : []);
      if (!rows.some((r) => r.id === created.id)) throw new Error(`${created.id} missing from ${rows.length} machines`);
      return { value: null, detail: `${rows.length} machines` };
    });

    if (cmux) {
      await J.step("link ensure (headless)", async () => {
        headlessLink = await startHeadlessLink(cmux, bound.host, install, backend.api, tag);
        return { value: null, detail: `socket ${headlessLink.linkSocket}` };
      });
    }

    const exec = cmux ? cliExec(cmux, api, created.id) : directExec(api, created.id, J);
    if (reuse) {
      // A kept machine still has the last run's model stub and its endpoint in Claude Code's settings, which the
      // login installer refuses: put both back as a fresh machine has them.
      await J.step("reset kept machine", async () => {
        const r = await exec(REUSE_RESET);
        if (r.code !== 0) throw new Error(`exit ${r.code} ${r.stderr.slice(-200)}`);
        return { value: null, detail: r.stdout.trim() || "clean" };
      });
    }
    await J.step("first exec", async () => {
      const r = await exec("echo journey-ok; uname -m");
      if (r.code !== 0 || !r.stdout.includes("journey-ok")) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
      return { value: null, detail: r.stdout.trim().split("\n").join(" ") };
    });

    if (keyedStart) {
      await J.step("keyed acpmux start holds", async () => {
        const status = async () => {
          const r = await exec(`${GUEST}"$c" acp --json daemon status 2>&1`);
          try { return JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))); } catch { return { raw: r.stdout.slice(-200) }; }
        };
        const r = await keyedAcpmuxStart(api, created.id, J.secrets);
        if (!r.ok) throw new Error(`keyed-start: ${r.detail}`);
        // acpmux.service is Restart=always with RestartSec=3: a unit the prepare step did not stop is back by now.
        await sleep(KEYED_SETTLE_MS);
        const after = await status();
        const why = keyedHoldProblem(r.personInstance, after);
        if (why) throw new Error(why);
        return { value: null, detail: `the keyed daemon still serves ${KEYED_SETTLE_MS / 1000} s later (pid ${after.pid ?? "?"})` };
      });
    }

    if (!provider || only.has("chat") || only.has("login")) {
      J.skip(loginStep, !provider ? `agent ${agent}` : "--skip");
    } else if (!login) {
      J.skip(loginStep, provider === "codex" ? "no CODEX_AUTH_JSON: the reply needs the person's Codex login on the machine" : "no CLAUDE_CODE_OAUTH_TOKEN: the reply needs the person's Claude login on the machine");
    } else {
      // CloudCredentialTransfer.perform on a Worker machines client: preflight, stage (exec as the work user makes
      // the folder, fs/write as root puts the file in 0644), install, each through the routes the app uses.
      await J.step(loginStep, async () => {
        if (!validLogin(provider, login)) throw new Error(provider === "codex" ? "CODEX_AUTH_JSON is not a Codex ChatGPT sign-in (auth.json with tokens)" : "CLAUDE_CODE_OAUTH_TOKEN is not a `claude setup-token` login");
        // On a team machine the journey is its creator and copies as a DEV or nightly build does (Release copies
        // only to an owner machine).
        const programs = loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), provider, Boolean(team));
        const pre = await waitPreflight(exec, programs.preflight, team ? "owner or team" : "owner");
        const folder = "/home/cmux/.cmux/credential-transfer";
        const made = await exec(`umask 077 && mkdir -p -- ${shq(folder)} && chmod 700 -- ${shq(folder)} && test -O ${shq(folder)} && test ! -L ${shq(folder)}`);
        if (made.code !== 0) throw new Error(`staging folder: exit ${made.code}`);
        const file = `${folder}/${randomUUID().toUpperCase()}.json`;
        try {
          const w = await api.raw("POST", `/v1/cloud/machines/${created.id}/fs/write`, { path: file, dataBase64: Buffer.from(login).toString("base64"), mode: 0o644 });
          if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write: HTTP ${w.status} ${short(w.body?.error?.code ?? "")}`);
          const done = await exec(programs.install(file));
          if (done.code !== 0) throw new Error(`installer exit ${done.code}`); // its output is never shown: it may name the token
        } catch (error) {
          // As the transfer does: a failed delivery leaves no second readable copy on the machine.
          await exec(`rm -f -- ${shq(file)}`).catch(() => null);
          throw error;
        }
        const own = await exec(`. /etc/cmux/agent-auth.sh >/dev/null 2>&1 && HOME=/home/cmux cmux_agent_has_own_login ${provider} && echo own-login`);
        if (!own.stdout.includes("own-login")) throw new Error(`installed, but the image's launcher does not see an own ${provider} login`);
        const waited = pre.tries > 1 ? ` (preflight passed on try ${pre.tries}, after ${Math.round(pre.waitedMs / 1000)} s)` : "";
        return { value: null, detail: `the person's own login, written by the app's installer; the launcher picks it${waited}` };
      });
    }

    const stubLog = "/home/cmux/.cmux/journey-model-stub.log";
    if (modelStub && provider && !only.has("chat")) {
      // The stub listens on the machine's loopback only; the harness's own settings point it there, after the login
      // copy (whose installer refuses a custom endpoint), so the forwarded login is sent nowhere but the stub:
      // Claude Code's settings.json ANTHROPIC_BASE_URL, or a Codex model provider that uses the ChatGPT sign-in (CODEX_STUB_CONFIG).
      await J.step("model stub on the machine", async () => {
        const file = "/home/cmux/.cmux/journey-model-stub.py";
        const script = "/home/cmux/.cmux/journey-model-stub.json";
        const ready = "/home/cmux/.cmux/journey-model-stub.ready";
        for (const [path, data] of [[file, readFileSync(MODEL_STUB_PY)], [script, Buffer.from(JSON.stringify(JOURNEY_STUB_SCRIPT))]] as const) {
          const w = await api.raw("POST", `/v1/cloud/machines/${created.id}/fs/write`, { path, dataBase64: data.toString("base64"), mode: 0o644 });
          if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${path}: HTTP ${w.status} ${short(w.body?.error?.code ?? "")}`);
        }
        // Port 0: the stub binds a free port and writes it to the ready file.
        const point = provider === "codex"
          ? `python3 - "$port" <<'PY'\n${CODEX_STUB_CONFIG}\nPY`
          : `python3 - "$port" <<'PY'\nimport json, pathlib, sys\np = pathlib.Path('/home/cmux/.claude/settings.json')\nc = json.loads(p.read_text()) if p.exists() else {}\nc.setdefault('env', {})['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + sys.argv[1]\np.write_text(json.dumps(c))\nprint('stub-ready')\nPY`;
        const r = await exec(
          `rm -f ${shq(stubLog)} ${shq(ready)}; (nohup python3 ${shq(file)} --port 0 --script ${shq(script)} --nonce ${shq(nonce)} --log ${shq(stubLog)} --ready-file ${shq(ready)} >${shq(stubLog)}.out 2>&1 &); ` +
            `for i in $(seq 50); do [ -s ${shq(ready)} ] && break; sleep 0.2; done; ` +
            `port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' ${shq(ready)} 2>/dev/null); ` +
            `[ -n "$port" ] && curl -fsS -m 2 "http://127.0.0.1:$port/__stub/info" | grep -q ${shq(nonce)} || { echo stub-down; tail -5 ${shq(stubLog)}.out; exit 1; }; ` +
            `echo "@@port $port"; ` + point,
        );
        if (!r.stdout.includes("stub-ready")) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
        const port = /@@port (\d+)/.exec(r.stdout)?.[1];
        return { value: null, detail: `the shared model stub at 127.0.0.1:${port}, nonce ${nonce}, one shell tool round trip (${provider})` };
      });
    }
    const session = `journey-${tag}`;
    if (only.has("chat")) {
      J.skip("start agent", "--skip chat");
    } else {
      await J.step(`start agent (${agent})`, async () => {
        const r = await exec(`${GUEST}"$c" acp ensure ${shq(session)} -m ${shq(agent)} --json 2>&1; echo "@@exit $?"`, 120_000);
        if (!/@@exit 0/.test(r.stdout)) throw new Error(r.stdout.slice(-400) || r.stderr.slice(-400));
        return { value: null, detail: `session ${session}` };
      });
      await J.step("send chat", async () => {
        const r = await exec(`${GUEST}printf '%s' ${shq(prompt)} | "$c" acp send --no-wait ${shq(session)} - 2>&1; echo "@@exit $?"`, 60_000);
        if (!/@@exit 0/.test(r.stdout)) throw new Error(r.stdout.slice(-400) || r.stderr.slice(-400));
        return { value: null, detail: prompt.slice(0, 80) };
      });
      await J.step("reply", async () => {
        const t0 = Date.now();
        let last = "";
        while (Date.now() - t0 < chatBudget) {
          const r = await exec(`${GUEST}"$c" acp wait ${shq(session)} --timeout 20 >/dev/null 2>&1; echo "@@wait $?"; "$c" acp last ${shq(session)} 2>&1; echo "@@lastexit $?"`, 45_000);
          const wait = /@@wait (\d+)/.exec(r.stdout)?.[1];
          last = r.stdout.replace(/@@wait \d+\n?/, "").replace(/@@lastexit \d+\s*$/, "").trim();
          if (wait === "0" && last) {
            // The stub repeats the Bash output in its reply, so this also proves the tool ran and its output came back.
            if (modelStub && !last.includes(`Stub reply ${nonce}. The tool printed ${nonce}-tool`)) throw new Error(`the reply does not carry the stub's nonce ${nonce} and the tool output: ${last.slice(-200)}`);
            return { value: last, detail: last.slice(0, 280) };
          }
          if (wait === "2") throw new Error(`the agent waits on a permission: ${last.slice(-200)}`);
          if (wait && wait !== "3" && wait !== "0") {
            // A failed turn (exit 1) prints no reply: name its error, e.g. a harness with no sign-in on the machine.
            const h = await exec(`${GUEST}"$c" acp tail ${shq(session)} 2>&1 | grep -E '"kind":"turn_error"' | tail -1`, 45_000).catch(() => null);
            const why = /"error":"((?:[^"\\]|\\.)*)"/.exec(h?.stdout ?? "")?.[1] ?? "";
            throw new Error(`acp wait exit ${wait}: ${(why || last).slice(-300)}`);
          }
        }
        throw new Error(`no reply within ${chatBudget / 1000} s; last: ${last.slice(-300)}`);
      });
      if (modelStub && provider) {
        await J.step("stub: forwarded login and a tool round trip", async () => {
          const r = await exec(`cat ${shq(stubLog)} 2>/dev/null`);
          const rows = r.stdout.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
          // Every model request the harness made: streamed or not, count_tokens and title side requests too.
          const route = provider === "codex" ? "/v1/responses" : "/v1/messages";
          const turns = rows.filter((x: any) => x.method === "POST" && String(x.path).startsWith(route));
          const want = createHash("sha256").update(loginBearer(provider, login)).digest("hex");
          if (!turns.some((x: any) => x.stream && !x.side)) throw new Error(`${agent} sent the stub no streamed ${route} turn`);
          if (!turns.every((x: any) => x.cred_sha256 === want)) throw new Error(`a model request did not carry the login the journey passed (the forwarded credential did not reach ${agent})`);
          if (!turns.some((x: any) => x.step === 1 && x.tool_results >= 1)) throw new Error("no tool round trip: no request came back with the shell call's result");
          return { value: null, detail: `${turns.length} model requests, each with the forwarded login (SHA-256 match); the shell call ran and its output came back` };
        });
      }
    }

    // A Native (vm-api) machine's link_token needs a Native device proof, which only an enrolled app install
    // makes (NativeDeviceEnrollment.swift). This install never enrolled, so that refusal is a SKIP with the
    // backend's own reason; any other refusal (a receiver that is not ready, a policy) stays red.
    await J.step("connect (connect_info)", async () => {
      const info = await installApi.read("cloud.machine.connect_info", { machine: created.id });
      return { value: null, detail: `host ${info.host} state ${info.state} epoch ${info.epoch}` };
    });
    const linkToken = await installApi.raw("POST", "/v1/ops", { op: "cloud.machine.link_token", params: { host: bound.host, services: ["daemon"] } })
      .catch((error: Error) => error);
    const nativeOnly = linkToken instanceof Error ? null : nativeProofSkip(linkToken.body);
    if (nativeOnly) {
      J.skip("connect (link_token)", nativeOnly);
      J.skip("connect (link dial)", nativeOnly);
    } else {
      await J.step("connect (link_token)", async () => {
        if (linkToken instanceof Error) throw new Error(`cloud.machine.link_token: ${linkToken.message}`);
        if (linkToken.status !== 200 || linkToken.body?.ok !== true) throw new Error(`cloud.machine.link_token: HTTP ${linkToken.status} ${short(linkToken.body?.error ?? linkToken.body)}`);
        const tok = linkToken.body.value;
        if (!tok?.expires_at) throw new Error(`link_token answered ${short(Object.keys(tok ?? {}))}`);
        return { value: null, detail: `link token until ${tok.expires_at}` };
      });
    }
    if (nativeOnly) {
      // link_token and link dial are recorded as skips above.
    } else if (headlessLink) {
      await J.step("connect (link dial)", async () => {
        const dial = spawnSync(cmux!, ["link", "dial", "--host", bound.host, "--service", "daemon", "--socket", headlessLink!.linkSocket], {
          input: '{"id":1,"cmd":"identify"}\n', encoding: "utf8", timeout: 45_000,
        });
        if (dial.error || dial.status !== 0) throw new Error(`link dial failed: ${dial.stderr || dial.error?.message}`);
        if (!dial.stdout.includes("capabilities") && !dial.stdout.includes('"data"')) throw new Error(`link dial returned no identify response: ${dial.stdout.slice(-300)}`);
        return { value: null, detail: dial.stdout.trim().split("\n").slice(-1)[0].slice(0, 280) };
      });
    } else {
      J.skip("connect (link dial)", "--cmux is required for a headless link dial");
    }

    // POST /v1/handoffs {sessionId, machine} (backend/apps/api/src/handoffs/routes.ts). Production leaves the
    // hand-off bindings unbound until it ships there and answers 404: that is a SKIP, not a red.
    // A transport error is recorded as this step's failure; the journey goes on to its next steps.
    const handoff = await api.raw("POST", "/v1/handoffs", { sessionId: session, machine: created.id }).catch((error: Error) => error);
    if (!(handoff instanceof Error) && handoff.status === 404) J.skip("handoff record", "hand-off is not deployed on this backend (404)");
    else await J.step("handoff record", async () => {
      if (handoff instanceof Error) throw new Error(`/v1/handoffs: ${handoff.message}`);
      if (handoff.status >= 300) throw new Error(`/v1/handoffs: HTTP ${handoff.status} ${short(handoff.body.error ?? handoff.body)}`);
      return { value: null, detail: `HTTP ${handoff.status} ${short(handoff.body.value?.id ?? handoff.body.id ?? handoff.body)}` };
    }).catch(() => undefined);
    J.skip("handoff (agent move)", "headless agent move requires a local session daemon socket; the Cloud guest session has no local source socket");

    if (only.has("sync")) J.skip("sync push/pull (folder round trip)", "--skip sync");
    else if (nativeOnly) J.skip("sync push/pull (folder round trip)", nativeOnly);
    else await J.step("sync push/pull (folder round trip)", async () => {
      if (!headlessLink) throw new Error("--cmux is required for link sync");
      const payload = Buffer.from(`journey ${tag} ${Date.now()}\n`.repeat(64)).toString("base64");
      const local = mkdtempSync(path.join(tmpdir(), `cmux-journey-sync-${tag}-`));
      const source = path.join(local, "file.txt");
      writeFileSync(source, Buffer.from(payload, "base64"));
      const remote = `/home/cmux/.cmux-journey-${tag}/sync`;
      const push = spawnSync(cmux!, ["link", "sync", "push", "--socket", headlessLink.bridgeSocket, local, remote], { encoding: "utf8", timeout: 120_000 });
      if (push.error || push.status !== 0) throw new Error(`sync push failed: ${push.stdout || push.stderr || push.error?.message}`);
      const mutate = await exec(`printf '%s' ${shq("remote-change\n")} >> ${shq(`${remote}/file.txt`)}`);
      if (mutate.code !== 0) throw new Error(`remote mutation failed: ${mutate.stderr}`);
      const pull = spawnSync(cmux!, ["link", "sync", "pull", "--socket", headlessLink.bridgeSocket, local, remote], { encoding: "utf8", timeout: 120_000 });
      if (pull.error || pull.status !== 0) throw new Error(`sync pull failed: ${pull.stdout || pull.stderr || pull.error?.message}`);
      const back = readFileSync(source, "utf8");
      rmSync(local, { recursive: true, force: true });
      if (!back.endsWith("remote-change\n")) throw new Error("pulled file did not include the remote change");
      return { value: null, detail: `${back.length} bytes pushed and pulled through link` };
    });

    if (!only.has("pause")) {
      await J.step("pause", async () => {
        await api.op("cloud.machine.pause", { machine: created.id }, `${tag}-pause`);
        const m = await waitMachine(api, created.id, (x) => x.status === "paused", 180_000);
        return { value: m, detail: `status ${m.status}` };
      });
      await J.step("resume", async () => {
        await api.op("cloud.machine.start", { machine: created.id }, `${tag}-start`);
        const m = await waitMachine(api, created.id, (x) => x.status === "running", 180_000);
        return { value: m, detail: `status ${m.status}` };
      });
      await J.step("exec after resume", async () => {
        const r = await exec("echo resumed");
        if (r.code !== 0 || !r.stdout.includes("resumed")) throw new Error(`exit ${r.code} ${r.stderr.slice(-200)}`);
        return { value: null, detail: "ok" };
      });
    }
    if (!keep) {
      await J.step("delete", async () => {
        await api.op("cloud.machine.delete", { machine: created.id }, `${tag}-delete`);
        deleted = true;
        const m = await waitMachine(api, created.id, (x) => x.status === "deleted" || x.status === "deleting", 120_000, true).catch(() => null);
        return { value: null, detail: `${created.id} ${m?.status ?? "gone"}` };
      });
    }
  } catch {
    // The failed step is recorded; cleanup below.
  } finally {
    process.off("SIGTERM", onSignal);
    process.off("SIGINT", onSignal);
    await cleanup();
  }
  const failed = J.steps.filter((s) => s.status === "fail");
  writeProbe();
  console.log(`\n${failed.length ? "FAIL" : "PASS"} ${backend.name}: ${J.steps.filter((s) => s.status === "pass").length} passed, ${failed.length} failed, ${J.steps.filter((s) => s.status === "skip").length} skipped, ${(J.steps.reduce((n, s) => n + s.ms, 0) / 1000).toFixed(1)} s`);
  return failed.length ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
