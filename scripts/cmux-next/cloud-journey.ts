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
 *   health -> sign in -> user.ensure -> install token -> sweep leaked journey machines -> create machine
 *   -> running (status) -> listed
 *   -> first exec -> pass Claude login -> start agent (acpmux on the machine) -> send chat -> reply -> turn 2 (same
 *   session) -> daemon restart keeps the session (the guest's agent daemon killed, then a turn) -> connect_info
 *   -> carrier dial (an identify answered over the machine's relay slot) -> handoff record -> pause -> resume
 *   -> carrier dial after resume -> turn after resume -> delete. `--skip lifecycle` leaves out the later turns and the daemon restart.
 *   --chaos adds the chaos leg after the carrier dial: a relay cut, 5 s and 60 s network drops, a session host and an
 *   agent daemon restart, each mid-turn and timed from a send at its end to the reply (cloud-chaos.ts).
 *
 * Each step prints PASS/FAIL/SKIP with its latency; --out DIR also gets journey.json (the steps) and
 * summary.md (a table for a PR comment or job summary). The machine this run made is deleted at the
 * end, pass or fail, by its exact id, unless --keep. A run that was killed before its cleanup leaves its
 * machines behind, holding the test account's machine quota: so before create (not with --machine or --keep),
 * the journey deletes `cloud journey auto jr-<tag>` machines (and their gateways) whose tag says they started
 * more than 3 hours ago (no journey job runs past 90 minutes) and that have had no activity for an hour, so a
 * running journey's machines are never touched.
 * Only a run that deletes its machine gives the `auto` name; a --keep run's plain `cloud journey jr-<tag>` is never
 * swept. Every page of the machine list is read, and each machine is logged before its delete.
 * A sweep error is recorded as a skip and the run goes on. Exit 0 only when no step failed.
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
 * --gateway CMUX_BIN: the chat machine holds no login at all (Leo, 2026-11-07: "VMs stop holding tokens"). A second
 * machine becomes the team's inference gateway: the person's own subscription proxy runs on it (--gateway-upstream URL,
 * or by default the shared model stub with the journey's nonce, as `stub`), and CMUX_BIN runs `cmux inference setup
 * --gateway-machine` (the install token in a 0600 file), which names it, starts `cmux inference gateway` there and
 * checks one real call from the chat machine. The chat's model calls then go chat machine -> coderouter edge -> cmux
 * (InferenceGateway) -> gateway machine -> proxy. Checked: the reply (with the stub, its nonce and tool round trip),
 * the gateway's log line for the chat machine's /v1/responses or /v1/messages, the proxy's own log, and that the chat
 * machine has no login file. The gateway machine is deleted with the chat machine.
 *
 * --gateway-local CMUX_BIN --gateway-upstream URL: the same chat, with `cmux inference gateway` on this computer (the
 * person's Mac) in front of the person's proxy at URL, holding this run's own install token in a 0600 file. Checked:
 * the reply, the local gateway's log line for the chat machine's call, and that the chat machine has no login file.
 * Either way the team is put in gateway mode before the chat machine is made (its edge route is picked when it is
 * made) and set back to its earlier mode at the end.
 *
 * Clean room: after the chat, the journey runs cloud-key-probe.py on the chat machine (as root when sudo asks no
 * password): every process's environment and command line, and the files under the homes, /etc, /opt, /srv and the
 * temp folders, searched for a model provider's key. The step names each finding by place and kind, never a value;
 * a run that could not read everything (not root, an unreadable file or process, the walk past its budget) is unknown.
 * With --gateway, --gateway-local or --keys-clean a finding or an unknown fails the step; otherwise it is report-only,
 * a skip that lists the findings (the login copy puts the person's login on the machine by design).
 * --keys-probe-out FILE appends the probe's whole answer with the run's tag and mode, one JSON line a run (back-to-back
 * runs keep every record); --skip keys leaves it out.
 *
 * --machines lists the agent test account's machines (one JSON line each, with `eligible` by the leaked journey
 * machine rule; --also-team T lists a second team too), and --delete-ids vm_a@JOB,vm_b@JOB deletes exactly those (at
 * most 5), each only when JOB is a trusted cmux-vm.yml deploy-staging job whose log shows it made the machine and its cleanup delete failed
 * (GITHUB_TOKEN reads it), the live list has it and the rule allows it, logged first (cmux-vm.yml action
 * journey-machines-staging).
 *
 * --desktop-link (with --cmux): once the machine runs, the desktop's UDP link instead of the chat. The journey is a
 * viewer of `cmux carrier dial --service desktop` (hello, start, a feedback datagram every half second) with its own
 * state dir, prints the account's team id and every `cloud.desktop_link machine=vm_… <note>` line of the dial's connect
 * log, writes them to desktop-link.json in --out, and fails unless a note is `up` or `host_up`. No line means the
 * platform sent no rd_link (the team's CLOUD_RD_LINK is off). Then the machine is deleted (cloud-rd-link-readback.yml).
 * --cleanup-tag jr-… deletes the machine a run with that tag made (`cloud journey auto jr-…`, its exact name), for a
 * workflow's always() step after a run cut off before its own cleanup. With --kept it also deletes the machine a
 * --keep run with that tag made (`cloud journey jr-…`), for the operator who kept it.
 *
 * --probe-out FILE writes the run as one synthetic-probe result row (cmuxterm-hq probes.py: probe, at,
 * outcome ok|fail, ms = send to first reply, error), --probe NAME naming it.
 *
 * Secrets are read from the environment or files, sent only in headers or request bodies, and never printed.
 */
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { appendFileSync, closeSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chaosProbeRow, countingTurnScript, runChaos } from "./cloud-chaos.ts";

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
// No word boundaries: a token glued to other characters (`prefix_<key>` in a path) is still a token.
const SECRET_SHAPES = [/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+/g, /(cmvm|cmk|cmuxvm_sk|cmm|pck|ssk)_[A-Za-z0-9_-]{8,}/g, /[Bb]earer\s+\S+/g,
  // Every shape in cloud-key-probe.py SHAPES, whatever text carries one: a probe answer, an error, a path. A test
  // holds one example of each probe shape and checks this list removes it, so a new shape cannot miss it.
  /sk-ant-[a-z]{3}\d\d-[A-Za-z0-9_-]{20,}/g, /sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}/g, /sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}/g,
  /sk-or-v1-[0-9a-f]{32,}/g, /AIza[0-9A-Za-z_-]{35}/g, /xai-[A-Za-z0-9]{40,}/g, /gsk_[A-Za-z0-9]{40,}/g, /hf_[A-Za-z0-9]{30,}/g,
  /(?:AKIA|ASIA)[0-9A-Z]{16}/g, /("refresh_token"\s*:\s*")[^"\s]{20,}"/g];
export function scrub(text: string, secrets: string[] = []): string {
  let out = text;
  for (const s of secrets) if (s && s.length >= 6) out = out.split(s).join("[secret]");
  for (const re of SECRET_SHAPES) out = out.replace(re, (whole, field?: string) => (typeof field === "string" ? `${field}[secret]"` : "[secret]"));
  return out;
}

/** A failed command's output for a step's detail: its start, where a CLI puts the error, and its end. */
const headTail = (out: string): string => (out.length <= 600 ? out : `${out.slice(0, 300)} ... ${out.slice(-300)}`);

export function summaryMarkdown(backend: Backend, steps: Step[], meta: Record<string, string> = {}): string {
  const failed = steps.filter((s) => s.status === "fail").length;
  const total = steps.reduce((n, s) => n + s.ms, 0);
  const head = `${failed ? "FAIL" : "PASS"}: Cloud journey on \`${backend.name}\` (${backend.api}), ${(total / 1000).toFixed(1)} s`;
  const extra = Object.entries(meta).map(([k, v]) => `${k}: ${v}`).join(", ");
  const rows = steps.map((s) => `| ${s.status === "pass" ? "pass" : s.status === "fail" ? "**FAIL**" : "skip"} | ${s.step} | ${s.ms} | ${s.detail.replace(/\|/g, "\\|").replace(/\n/g, " ").slice(0, 1000)} |`);
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
      this.record({ step: name, status: "fail", ms: Date.now() - t0, detail: String((error as Error)?.message ?? error).slice(0, 1000) });
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

const OP_ATTEMPTS = 3;
/** How long a machine delete keeps retrying an indeterminate answer under its key. */
const DELETE_BUDGET_MS = 180_000;
/** The ops API says a provider call was cut off and the same idempotency key may be sent again. */
export const opRetryable = (body: any): boolean => body?.ok !== true && body?.error?.code === "mutation.indeterminate" && body?.error?.retryable === true;

class Api {
  bearer = "";
  constructor(readonly origin: string, readonly team?: string) {}
  private headers(): Record<string, string> {
    return { authorization: `Bearer ${this.bearer}`, ...(this.team ? { "x-cmux-team": this.team } : {}) };
  }
  async op(op: string, params: unknown, key?: string): Promise<any> {
    for (let attempt = 1; ; attempt++) {
      const r = await http("POST", `${this.origin}/v1/ops`, { op, params, ...(key ? { idempotency_key: key } : {}) }, this.headers(), 60_000);
      // A provider call cut off mid-way is safe to repeat under the same key; without it a cleanup delete leaks the VM.
      if (key && attempt < OP_ATTEMPTS && opRetryable(r.body)) { await sleep(2000 * attempt); continue; }
      if (r.status !== 200 || r.body.ok !== true) throw new Error(`${op}: HTTP ${r.status} ${short(r.body.error ?? r.body)}`);
      return r.body.value;
    }
  }
  /**
   * A machine delete that must not leak: retried under the same key while the ops API answers it was cut off
   * (mutation.indeterminate, retryable), for up to `budgetMs`. op() gives up after three tries in about six
   * seconds, which leaked a machine on a 502 storm (cmux-vm run 42485334511).
   */
  async deleteMachine(machine: string, key: string, budgetMs = DELETE_BUDGET_MS): Promise<any> {
    const until = Date.now() + budgetMs;
    for (let attempt = 1; ; attempt++) {
      const r = await http("POST", `${this.origin}/v1/ops`, { op: "cloud.machine.delete", params: { machine }, idempotency_key: key }, this.headers(), 60_000);
      if (opRetryable(r.body) && Date.now() < until) { await sleep(Math.min(2000 * attempt, 15_000)); continue; }
      if (r.status !== 200 || r.body.ok !== true) throw new Error(`cloud.machine.delete: HTTP ${r.status} ${short(r.body.error ?? r.body)}`);
      return r.body.value;
    }
  }
  async read(op: string, params: unknown, timeoutMs = 30_000): Promise<any> {
    const r = await http("POST", `${this.origin}/v1/read`, { op, params }, this.headers(), timeoutMs);
    if (r.status !== 200 || (r.body.ok === false)) throw new Error(`${op}: HTTP ${r.status} ${short(r.body.error ?? r.body)}`);
    return r.body.value;
  }
  async raw(method: string, route: string, body?: unknown, timeoutMs = 60_000): Promise<Answer> {
    return http(method, `${this.origin}${route}`, body, this.headers(), timeoutMs);
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
export function directExec(api: Api, machine: string, journey: Journey): Exec {
  let session: { token: string; vm_id: string; linux_user: string; api_base_url: string; expires_at: number } | null = null;
  let guestRoute = false;
  const guestExec: Exec = async (command, timeoutMs = 60_000) => {
    // A VM API machine has no client sessions: the machine exec route (MachineGuest.ts) runs it instead.
    // The HTTP request waits as long as the command may run, plus room for the answer to travel.
    const runMs = Math.min(timeoutMs, 300_000);
    const g = await api.raw("POST", `/v1/cloud/machines/${machine}/exec`, { command, timeoutMs: runMs }, runMs + 15_000);
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
    // Asynchronous, so a carrier dial this process holds (the chaos leg's) keeps being read while a command runs.
    const done = await new Promise<{ status: number | null; stdout: string; stderr: string }>((resolve, reject) => {
      const child = spawn(cmux, args, { env, stdio: ["ignore", "pipe", "pipe"] });
      let stdout = "";
      let stderr = "";
      child.stdout!.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk));
      child.stderr!.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
      const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs + 30_000);
      child.on("error", (error) => {
        clearTimeout(timer);
        reject(new Error(`${cmux}: ${error.message}`));
      });
      child.on("close", (status) => {
        clearTimeout(timer);
        resolve({ status, stdout, stderr });
      });
    });
    try {
      const result = JSON.parse(done.stdout);
      if (Number.isInteger(result?.exit_code)) {
        return { code: Number(result.exit_code), stdout: String(result.stdout ?? ""), stderr: String(result.stderr ?? "") };
      }
    } catch {
      // Preserve the raw CLI answer below when it did not produce its JSON contract.
    }
    return { code: done.status ?? 1, stdout: done.stdout, stderr: done.stderr };
  };
}

/** An awk function that reads one string field of a journalctl JSON line, past escaped quotes (`\"` reads as `"`). */
export const JOURNAL_FIELD = `function field(name,   r) { if (match($0, "\\"" name "\\":\\"([^\\"\\\\\\\\]|\\\\\\\\.)*\\"")) { r = substr($0, RSTART, RLENGTH); sub(/^"[^"]*":"/, "", r); sub(/"$/, "", r); gsub(/\\\\"/, "\\"", r); return r } return "" }`;

/**
 * When the guest set up its carrier: the bind the host finished (bound.json; the platform's bind.json is gone by now,
 * since the host deletes it once bound.json is written, cmux-host cloud/client.rs), the carrier.json and grant the host
 * wrote from it, the session host's start (it is respawned with the relay flags), and the host's journal lines about
 * them. Times are on the guest's boot clock where it has one, so a wall clock stepped after boot (a machine resumed
 * from a snapshot, then synced) moves nothing: `guest_now <wall ms> <uptime ms>` read together, `mono <name> <ms since
 * boot>` (the session host), `journal <ms since boot> <message>`, `wall <name> <epoch ms>` (a file's mtime) and
 * `clock <epoch ms> <boot's epoch ms>` each time the journal's wall clock moved against its boot clock. The pid and the
 * journal may need root: each tries `sudo -n` (journalctl run without root can exit 0 with nothing to show).
 */
export const GUEST_CARRIER_TIMELINE = [
  `echo "guest_now $(date +%s%3N) $(awk '{ printf "%.0f", $1 * 1000 }' /proc/uptime)"`,
  "for f in /var/lib/cmux/bound.json /var/lib/cmux/carrier.json /run/cmux/carrier-grant.json; do",
  '  t=$(date -r "$f" +%s%3N 2>/dev/null || sudo -n date -r "$f" +%s%3N 2>/dev/null) && echo "wall $(basename "$f") $t"',
  "done",
  "pid=$(cat /run/cmux-host/daemon.pid 2>/dev/null || sudo -n cat /run/cmux-host/daemon.pid 2>/dev/null)",
  'if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then',
  "  st=$(awk '{print $22}' \"/proc/$pid/stat\"); hz=$(getconf CLK_TCK)",
  "  awk -v s=\"$st\" -v h=\"$hz\" 'BEGIN { printf \"mono session_host_start %.0f\\n\", s * 1000 / h }'",
  "fi",
  "{ sudo -n journalctl -b -o json --no-pager 2>/dev/null || journalctl -b -o json --no-pager 2>/dev/null; } | head -n 4000 \\",
  `  | awk '${JOURNAL_FIELD} { rt = field("__REALTIME_TIMESTAMP"); mo = field("__MONOTONIC_TIMESTAMP"); if (rt == "" || mo == "") next; bw = (rt - mo) / 1000; if (!n || bw - last > 500 || last - bw > 500) { printf "clock %.0f %.0f\\n", rt / 1000, bw; last = bw; n++ } }'`,
  "{ sudo -n journalctl -b -u cmux-host.service -o json --no-pager -n 400 2>/dev/null || journalctl -b -u cmux-host.service -o json --no-pager -n 400 2>/dev/null; } \\",
  `  | awk '${JOURNAL_FIELD} { m = field("MESSAGE"); if (tolower(m) ~ /carrier|session host|relay|regist/) line[++n] = sprintf("journal %.0f %s", field("__MONOTONIC_TIMESTAMP") / 1000, m) } END { for (i = (n > 8 ? n - 7 : 1); i <= n; i++) print line[i] }'`,
  "true",
].join("\n");

/**
 * GUEST_CARRIER_TIMELINE's lines as ms after create's answer. Each time goes to the guest's boot clock (a file's mtime
 * through the wall clock segment it was written in), then to this computer's clock through the uptime read at the
 * exec's midpoint (`before`, `after`), so a time is good to about half the exec, whatever the guest's wall clock did.
 */
export function guestTimeline(stdout: string, answeredAt: number, before: number, after: number, sentAt = answeredAt): string {
  let wallNow = NaN;
  let upNow = NaN;
  const segments: Array<{ rt: number; boot: number }> = [];
  const events: Array<{ name: string; mono?: number; wall?: number; text?: string }> = [];
  for (const line of stdout.split("\n").map((l) => l.trim()).filter(Boolean)) {
    const [kind, a, b, ...rest] = line.split(" ");
    if (kind === "guest_now") [wallNow, upNow] = [Number(a), Number(b)];
    else if (kind === "clock") segments.push({ rt: Number(a), boot: Number(b) });
    else if (kind === "wall") events.push({ name: a, wall: Number(b) });
    else if (kind === "mono") events.push({ name: a, mono: Number(b) });
    else if (kind === "journal") events.push({ name: "journal", mono: Number(a), text: [b, ...rest].join(" ") });
  }
  const half = Math.round((after - before) / 2);
  if (!Number.isFinite(wallNow) || !Number.isFinite(upNow)) return `after create's answer (±${half} ms): no guest clock read`;
  const bootNow = wallNow - upNow;
  const clock = segments.filter((c) => Number.isFinite(c.rt) && Number.isFinite(c.boot));
  if (!clock.length || Math.abs(clock[clock.length - 1].boot - bootNow) > 500) clock.push({ rt: wallNow, boot: bootNow });
  // A wall time in the boot clock, through the segment whose boot-clock span it falls in.
  const toMono = (wall: number) => {
    for (let i = 0; i < clock.length; i += 1) {
      const mono = wall - clock[i].boot;
      const start = i === 0 ? -Infinity : clock[i].rt - clock[i].boot;
      const end = i + 1 < clock.length ? clock[i + 1].rt - clock[i + 1].boot : Infinity;
      if (mono >= start && mono < end) return mono;
    }
    return wall - bootNow;
  };
  const mid = Math.round((before + after) / 2);
  const rel = (mono: number) => {
    const ms = Math.round(mid - (upNow - mono) - answeredAt);
    return `${ms >= 0 ? "+" : ""}${ms} ms`;
  };
  const parts = [`guest boot ${rel(0)}`, ...events.flatMap((e) => {
    const mono = e.mono ?? (e.wall !== undefined ? toMono(e.wall) : NaN);
    return Number.isFinite(mono) ? [`${e.name}${e.text ? ` "${e.text.slice(0, 80)}"` : ""} ${rel(mono)}`] : [];
  })];
  const step = clock.length > 1 ? Math.round(clock[clock.length - 1].boot - clock[0].boot) : 0;
  // A machine bound before create was sent is a claimed spare (made and bound ahead, handed out at create); a cold
  // machine can bind while create's answer is on its way back, so the send, not the answer, is the line. Its boot
  // time is the snapshot base's, so the bind, not the boot, is what says so.
  const bound = events.find((e) => e.name === "bound.json" && e.wall !== undefined);
  const boundAt = bound ? mid - (upNow - toMono(bound.wall!)) : NaN;
  const spare = boundAt < sentAt ? `; a claimed spare: bound ${Math.round(answeredAt - boundAt)} ms before create answered` : "";
  return `after create's answer (±${half} ms${step ? `; the guest's wall clock stepped ${step >= 0 ? "+" : ""}${step} ms after boot` : ""}${spare}): ${parts.join("; ")}`;
}

/** A carrier answer's `relay`, as the dial takes it (cmux-tui carrier/answer.rs relay_route): a bare `relay+do://<host>`. */
function relayDoProblem(text: unknown): string | null {
  if (typeof text !== "string") return "relay is missing";
  let url: URL;
  try { url = new URL(text); } catch { return "relay is not a URL"; }
  const bare = !url.username && !url.password && !url.search && !url.hash && (url.pathname === "" || url.pathname === "/");
  return url.protocol === "relay+do:" && bare && url.hostname ? null : "relay is not a relay+do:// origin";
}

/** A ticket or grant as the dial takes it (answer.rs secret): 1 to 4096 visible ASCII bytes. */
const visibleSecret = (v: unknown): boolean => typeof v === "string" && /^[\x21-\x7e]{1,4096}$/.test(v);

/** A canonical 32-byte base64url key without padding (answer.rs key_bytes: it re-encodes to the same text). */
export function canonicalKey(v: unknown): boolean {
  if (typeof v !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(v)) return false;
  const bytes = Buffer.from(v, "base64url");
  return bytes.length === 32 && bytes.toString("base64url") === v;
}

/**
 * What `cmux carrier dial` would refuse in a POST /v1/cloud/machines/{id}/carrier answer for a person who sent a
 * noise_key (cmux-platform CarrierRoute.ts), or null when the dial would take it. The rules are answer.rs
 * parse_answer's (relay, slot, ticket, expires_at, grant) and client.rs pinned_daemon's (the daemon key a dial pins),
 * plus a ticket still live and a grant present, which a dial with a noise_key needs.
 */
export function carrierTicketProblem(status: number, body: any, nowS = Date.now() / 1000): string | null {
  if (status !== 200 || body?.ok !== true) return `HTTP ${status} ${short(body?.error ?? body)}`;
  const v = body.value ?? {};
  const relay = relayDoProblem(v.relay);
  if (relay) return relay;
  if (typeof v.slot !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(v.slot)) return "slot is not 1 to 128 base64url characters";
  if (!visibleSecret(v.ticket)) return "ticket is not 1 to 4096 visible ASCII bytes";
  if (!Number.isSafeInteger(v.expires_at) || v.expires_at < 0) return "expires_at is missing";
  if (v.expires_at <= nowS) return `the ticket is not live (expires_at ${v.expires_at})`;
  if (!visibleSecret(v.grant)) return "grant is not 1 to 4096 visible ASCII bytes";
  if (!canonicalKey(v.daemon_key)) return "no canonical 32-byte daemon_key: the dial refuses an answer without one";
  return null;
}

/** The carrier dials still running, so a cancelled journey stops them instead of leaving them to their deadline. */
const carrierDials = new Set<ReturnType<typeof spawn>>();
/** Their state dirs, which a cancel (SIGTERM skips `finally`) removes too. */
const carrierStateDirs = new Set<string>();

/**
 * `cmux carrier dial` (design/cloud-carrier.md): this device reaches the machine's session daemon over its relay slot,
 * with the person's credential, as the app will. It passes when the dial reports the carrier route and one identify
 * line gets the daemon's answer. connectMs is the dial's own `cloud.connect ... ms=` (ticket, relay, Noise handshake);
 * replyMs runs from the spawn to the answer.
 */
/**
 * The dial's `carrier.phases` lines (cmux-tui carrier/contract.rs phases_line, one per attempt, written only to the
 * connect log) as `<phase> <outcome>: ticket N, relay N, parked N, handshake N, mux N ms, lanes N, N ms`, without the
 * machine id. A key the line does not have is left out, so a later field (a detail) shows as `key value`.
 */
export function dialPhases(log: string): string[] {
  const named = ["ticket_ms", "relay_ms", "parked_ms", "handshake_ms", "mux_ms"];
  return log.split("\n").filter((l) => l.startsWith("carrier.phases ")).map((line) => {
    const f = Object.fromEntries(line.split(" ").slice(1).map((kv) => kv.split("=")).filter((kv) => kv.length === 2));
    const steps = named.filter((k) => k in f).map((k) => `${k.replace(/_ms$/, "")} ${f[k]}`);
    const rest = Object.keys(f).filter((k) => ![...named, "machine", "phase", "carrier", "outcome", "lanes", "ms"].includes(k));
    return `${f.phase} ${f.outcome}: ${steps.join(", ")} ms${"lanes" in f ? `, lanes ${f.lanes}` : ""}${rest.map((k) => `, ${k} ${f[k]}`).join("")}, ${f.ms} ms`;
  });
}

/** A carrier dial step's detail: the connect and reply times, the failed attempts, and each attempt's phases. */
export function dialDetail(d: { connectMs: number; replyMs: number; retries: number; failed: string[]; phases: string[]; reply: string }): string {
  return `connect ${d.connectMs} ms, reply ${d.replyMs} ms, ${d.retries} retried attempts${d.failed.length ? ` (${d.failed.join(", ")})` : ""}`
    + `${d.phases.length ? `; phases: ${d.phases.join("; ")}` : ""}: ${d.reply.slice(0, 160)}`;
}

export async function carrierDial(cmux: string, api: Pick<Api, "origin" | "bearer" | "team">, machine: string, deadlineMs = 45_000): Promise<{ connectMs: number; replyMs: number; retries: number; failed: string[]; phases: string[]; reply: string }> {
  const started = performance.now();
  // The dial's own state dir, so its connect log holds only this dial's lines (the device key is not kept there).
  const stateDir = mkdtempSync(path.join(tmpdir(), "cmux-carrier-"));
  carrierStateDirs.add(stateDir);
  const phases = () => {
    try {
      return dialPhases(readFileSync(path.join(stateDir, "carrier", "connect.log"), "utf8"));
    } catch {
      return [];
    }
  };
  // The team is the journey's own or none: an inherited CMUX_CLOUD_TEAM would send a header its API calls do not.
  const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
  const env = { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer, CMUX_TUI_STATE_DIR: stateDir };
  const args = ["carrier", "dial", "--machine", machine, "--deadline-ms", String(deadlineMs), ...(api.team ? ["--team", api.team] : [])];
  const child = spawn(cmux, args, { env, stdio: ["pipe", "pipe", "pipe"] });
  carrierDials.add(child);
  child.on("exit", () => carrierDials.delete(child));
  // A cmux that does not start, or a dial that exits before its stdin is written, fails this step, not the journey.
  let failed: Error | null = null;
  const failure = new Promise<never>((_, reject) => {
    child.on("error", (e) => reject((failed = new Error(`carrier dial: ${e.message}`))));
    child.stdin!.on("error", (e) => reject((failed = new Error(`carrier dial: stdin ${e.message}`))));
  });
  failure.catch(() => undefined);
  const lines = (stream: NodeJS.ReadableStream) => {
    let buffered = "";
    const waiting: Array<(line: string | null) => void> = [];
    const queued: Array<string | null> = [];
    const push = (line: string | null) => (waiting.length ? waiting.shift()!(line) : queued.push(line));
    stream.setEncoding("utf8");
    stream.on("data", (chunk: string) => {
      buffered += chunk;
      for (let at = buffered.indexOf("\n"); at >= 0; at = buffered.indexOf("\n")) {
        push(buffered.slice(0, at));
        buffered = buffered.slice(at + 1);
      }
    });
    stream.on("end", () => push(null));
    return () => new Promise<string | null>((resolve) => (queued.length ? resolve(queued.shift()!) : waiting.push(resolve)));
  };
  const err = lines(child.stderr!);
  const out = lines(child.stdout!);
  const within = <T,>(what: string, p: Promise<T>) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`carrier dial: no ${what} within ${deadlineMs + 15_000} ms`)), deadlineMs + 15_000);
    });
    return Promise.race([p, late, failure]).finally(() => clearTimeout(timer));
  };
  try {
    // stderr: the JSON status line, and a `cloud.connect route=carrier ... outcome=<ok|error_code> ms=N` line per
    // connection attempt. A failed attempt the dial retries is counted, not fatal; the ok attempt's ms is the connect time.
    let status: any = undefined;
    let connectMs = NaN;
    let retries = 0;
    const failed: string[] = [];
    // A dial that gives up still says which attempts failed and how.
    const attempts = (message: string) => new Error(failed.length ? `${message} (failed attempts: ${failed.join(", ")})` : message);
    while (status === undefined || !Number.isFinite(connectMs)) {
      const line = await within(status === undefined ? "status line" : "ok route line", err()).catch((e: Error) => {
        throw attempts(e.message);
      });
      if (line === null) throw attempts(`carrier dial: ${status === undefined ? "ended with no status line" : "ended with no ok route line"}`);
      const attempt = /^cloud\.connect route=carrier .*outcome=(\S+) ms=(\d+)/.exec(line);
      // The dial's status line comes first (cmux-tui spec/cli.md), so a route line before it is out of contract.
      if (attempt && status === undefined) throw new Error(`carrier dial: a route line before the status line: ${short(line)}`);
      if (attempt) {
        if (attempt[1] === "ok") connectMs = Number(attempt[2]);
        else {
          retries += 1;
          failed.push(`${attempt[1]} ${attempt[2]} ms`);
        }
        continue;
      }
      if (status !== undefined) throw new Error(`carrier dial: unexpected line ${short(line)}`);
      try {
        status = JSON.parse(line);
      } catch {
        throw new Error(`carrier dial: not a status line: ${short(line)}`);
      }
      if (status?.ok !== true) {
        // A dial that gives up writes its status line first, then the route line of every attempt it made.
        const next = () => within("route lines", err()).catch(() => null);
        for (let rest = await next(); rest !== null; rest = await next()) {
          const tried = /^cloud\.connect route=carrier .*outcome=(\S+) ms=(\d+)/.exec(rest);
          if (tried && tried[1] !== "ok") failed.push(`${tried[1]} ${tried[2]} ms`);
        }
        throw attempts(`carrier dial: ${short(status)}`);
      }
      if (status.route !== "carrier") throw new Error(`carrier dial: route ${status.route}, not carrier`);
    }
    child.stdin!.write('{"cmd":"identify","id":1}\n');
    // The daemon may push events first; the answer is the line with id 1, and it must be ok with the daemon's identity.
    for (;;) {
      const reply = await within("answer to identify", out());
      if (reply === null) throw new Error("carrier dial: the stream ended before the daemon answered");
      let answer: any;
      try {
        answer = JSON.parse(reply);
      } catch {
        throw new Error(`carrier dial: not a protocol line: ${reply.slice(0, 200)}`);
      }
      if (answer?.id !== 1) continue;
      if (answer.ok !== true || typeof answer.data?.app !== "string") throw new Error(`carrier dial: identify answered ${short(answer)}`);
      return { connectMs, replyMs: Math.round(performance.now() - started), retries, failed, phases: phases(), reply };
    }
  } catch (e) {
    // Every way a dial fails shows each attempt's phases, read before the dir goes.
    const tried = phases();
    throw tried.length ? new Error(`${(e as Error).message} (phases: ${tried.join("; ")})`) : e;
  } finally {
    if (!failed) child.stdin!.end();
    child.kill("SIGTERM");
    rmSync(stateDir, { recursive: true, force: true });
    carrierStateDirs.delete(stateDir);
  }
}

/** A `cmux.rd/1` frame on the dial's stdin and stdout: u8 type (1 control JSON, 2 datagram), u32 little-endian length, payload. */
export function rdFrame(type: 1 | 2, payload: Uint8Array): Buffer {
  const head = Buffer.alloc(5);
  head[0] = type;
  head.writeUInt32LE(payload.length, 1);
  return Buffer.concat([head, payload]);
}

/**
 * An empty viewer feedback datagram: the 16-byte header (cmux-rd-proto datagram.rs: version 1 in the high nibble, kind
 * 7 Feedback, the rest 0), then feedback.rs's payload with nothing acked, no recovery, no arrivals and no NACKs. The
 * host ends a session after 3 s without feedback (cmux-rd-host stream.rs LIVENESS_NS), sooner than a link through NAT
 * may come up.
 */
export const RD_FEEDBACK = Buffer.concat([Buffer.from([0x10, 7]), Buffer.alloc(14), Buffer.alloc(12)]);

/** The viewer's hello: the app's (RemoteRdHello.cloudDesktop), no token (the link's owner is the carrier's person). */
export const RD_HELLO = { t: "hello", user: "cloud-journey", install: "cloud-journey", class: "user", interactive: true, udp_port: null, max_datagram: 1200, service: "desktop", caps: [] as string[] };

/** The `cloud.desktop_link machine=vm_… <note>` lines of a dial's connect log (cmux-tui carrier/mod.rs). */
export function desktopLinkLines(log: string): string[] {
  return log.split("\n").filter((l) => l.startsWith("cloud.desktop_link "));
}

/** A desktop_link line's note: `answered`, `up`, `host_up`, `failed …`, `not_answered`, `host_down …`, `not_offered …`. */
export function desktopLinkNote(line: string): string {
  return line.replace(/^cloud\.desktop_link machine=\S+ ?/, "");
}

/** Addresses in a public log are left out: a candidate keeps its kind, never the runner's or the machine's address. */
export function maskAddresses(text: string): string {
  return text.replace(/\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b/g, "<addr>").replace(/\[?\b[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){2,7}\]?(?::\d+)?/gi, "<addr>");
}

/** Up when a note says the link is up on either side; else why not, by the note that names it. */
export function desktopLinkVerdict(lines: string[]): { up: boolean; why: string } {
  const notes = lines.map(desktopLinkNote);
  const up = notes.filter((n) => /^(up|host_up)\b/.test(n));
  if (up.length) return { up: true, why: `the link came up (${up.join(", ")})` };
  if (!notes.length) return { up: false, why: "no cloud.desktop_link line: the platform sent no rd_link for this team (CLOUD_RD_LINK off), or the dial never reached the desktop" };
  if (notes.some((n) => n.startsWith("not_answered"))) return { up: false, why: "not_answered: the host's welcome has no link.udp (an image without cmux-rd 0.2.3 --link-stun)" };
  return { up: false, why: `the link did not come up: ${notes.join("; ")}` };
}

/** Every team id named in these values (`team_<id>`), once each, in order. */
export function teamIdsIn(...values: unknown[]): string[] {
  return [...new Set(values.flatMap((v) => JSON.stringify(v ?? null).match(/\bteam_[0-9a-z]{8,64}\b/g) ?? []))];
}

export type DesktopLinkRun = { status: unknown; controls: string[]; datagrams: number; lines: string[]; error: string | null; ms: number };

/**
 * `cmux carrier dial --service desktop` with this run as the viewer: once the dial's status line is ok, a hello and a
 * view-only start, then an empty feedback datagram every 500 ms after `started`, as the app's viewer keeps the session.
 * The dial splices the link in (rd_link.rs) and writes its notes to its own connect log. It stops 3 s after the first
 * final note (up, host_up or a failure, so both sides' up are read), when the host ends the session, or after holdMs.
 * Never throws for what the dial said: the caller reads the lines.
 */
export async function desktopLinkDial(cmux: string, api: Pick<Api, "origin" | "bearer" | "team">, machine: string, holdMs = 45_000, deadlineMs = 60_000): Promise<DesktopLinkRun> {
  const started = performance.now();
  const stateDir = mkdtempSync(path.join(tmpdir(), "cmux-desktop-link-"));
  carrierStateDirs.add(stateDir);
  const log = () => {
    try {
      return readFileSync(path.join(stateDir, "carrier", "connect.log"), "utf8");
    } catch {
      return "";
    }
  };
  const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
  const env = { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer, CMUX_TUI_STATE_DIR: stateDir };
  const args = ["carrier", "dial", "--machine", machine, "--service", "desktop", "--deadline-ms", String(deadlineMs), ...(api.team ? ["--team", api.team] : [])];
  const child = spawn(cmux, args, { env, stdio: ["pipe", "pipe", "pipe"] });
  carrierDials.add(child);
  let exited = false;
  let error: string | null = null;
  child.on("exit", () => {
    exited = true;
    carrierDials.delete(child);
  });
  child.on("error", (e) => {
    exited = true;
    error ??= `carrier dial: ${e.message}`;
  });
  child.stdin!.on("error", () => undefined);
  const write = (bytes: Buffer) => {
    if (!exited && child.stdin!.writable) child.stdin!.write(bytes);
  };
  let status: unknown = undefined;
  let errText = "";
  child.stderr!.setEncoding("utf8");
  child.stderr!.on("data", (chunk: string) => {
    errText += chunk;
    for (let at = errText.indexOf("\n"); at >= 0; at = errText.indexOf("\n")) {
      const line = errText.slice(0, at);
      errText = errText.slice(at + 1);
      if (status !== undefined) continue;
      try {
        status = JSON.parse(line);
      } catch {
        status = { ok: false, not_a_status_line: line.slice(0, 200) };
      }
    }
  });
  const controls: string[] = [];
  let datagrams = 0;
  let feedback: ReturnType<typeof setInterval> | undefined;
  let pending = Buffer.alloc(0);
  child.stdout!.on("data", (chunk: Buffer) => {
    pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
    while (pending.length >= 5) {
      const size = pending.readUInt32LE(1);
      if (pending.length < 5 + size) break;
      const type = pending[0];
      const payload = pending.subarray(5, 5 + size);
      pending = pending.subarray(5 + size);
      if (type !== 1) {
        datagrams += 1;
        continue;
      }
      let name = "?";
      try {
        const c = JSON.parse(payload.toString("utf8"));
        name = `${c.t}${typeof c.reason === "string" ? ` ${c.reason}` : ""}`;
      } catch { /* counted as "?" */ }
      controls.push(name.slice(0, 160));
      if (name === "started" && !feedback) feedback = setInterval(() => write(rdFrame(2, RD_FEEDBACK)), 500);
    }
  });
  try {
    const statusBy = Date.now() + deadlineMs + 15_000;
    while (status === undefined && !exited && Date.now() < statusBy) await sleep(100);
    if (status === undefined) error ??= exited ? "carrier dial: ended with no status line" : `carrier dial: no status line within ${deadlineMs + 15_000} ms`;
    else if ((status as any)?.ok !== true) error = `carrier dial: ${short(status)}`;
    else {
      write(rdFrame(1, Buffer.from(JSON.stringify(RD_HELLO))));
      write(rdFrame(1, Buffer.from(JSON.stringify({ t: "start", key: randomUUID(), mode: "view" }))));
      const until = Date.now() + holdMs;
      let settleBy = Infinity;
      while (!exited && Date.now() < Math.min(until, settleBy)) {
        await sleep(250);
        const notes = desktopLinkLines(log()).map(desktopLinkNote);
        if (settleBy === Infinity && notes.some((n) => /^(up|host_up|failed|not_answered|not_offered|not_started|host_down)\b/.test(n))) settleBy = Date.now() + 3_000;
        if (controls.some((c) => c.startsWith("ended") || c.startsWith("refused"))) break;
      }
      if (exited && !error) error = "carrier dial: ended while the desktop was open";
    }
    return { status, controls, datagrams, lines: desktopLinkLines(log()), error, ms: Math.round(performance.now() - started) };
  } finally {
    clearInterval(feedback);
    child.stdin!.end();
    child.kill("SIGTERM");
    rmSync(stateDir, { recursive: true, force: true });
    carrierStateDirs.delete(stateDir);
  }
}

/**
 * --cleanup-tag TAG: deletes the machines a journey run with this tag made (`cloud journey auto TAG` and its gateway,
 * by exact name, never another run's), each logged first. For a workflow's always() step: the run's own cleanup is
 * the first line, this the second when the run was cut off.
 */
async function cleanupTagMode(tag: string, backend: Backend, email: string | undefined, password: string | undefined, team: string | undefined, kept = false): Promise<number> {
  if (!/^jr-[0-9a-z]{1,16}$/.test(tag)) throw new Error(`--cleanup-tag ${JSON.stringify(tag.slice(0, 40))}: not a journey tag (jr-<base36>)`);
  if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
  const secrets = [password];
  const s = await passwordSignIn(STACK[backend.stack], email, password);
  secrets.push(s.access, s.refresh);
  const api = new Api(backend.api, team);
  api.bearer = s.access;
  const names = new Set([`cloud journey auto ${tag}`, `cloud journey auto ${tag} gateway`]);
  // --kept: also the machine a --keep run with this tag made (`cloud journey TAG`), once its operator is done with it.
  if (kept) names.add(`cloud journey ${tag}`).add(`cloud journey ${tag} gateway`);
  const rows = await listAllMachines((params) => api.read("cloud.machine.list", params));
  const mine = rows.filter((r) => names.has(r?.name) && r.status !== "deleted" && r.status !== "deleting");
  let failed = 0;
  for (const r of mine) {
    const id = String(r.id ?? r.machine_id ?? "");
    console.log(JSON.stringify({ deleting: id, name: r.name, status: r.status }));
    await api.deleteMachine(id, `${tag}-tag-cleanup-${id}`).catch((e: Error) => {
      failed += 1;
      console.log(scrub(JSON.stringify({ failed: id, error: String(e?.message ?? e).slice(0, 300) }), secrets));
    });
  }
  console.log(JSON.stringify({ tag, found: mine.length, deleted: mine.length - failed }));
  return failed ? 1 : 0;
}

/**
 * The run as one synthetic-probe result row (cmuxterm-hq tools/fleet-reconcilers/probes.py): ok only when a reply
 * was read back, with ms from the send to the first reply; otherwise fail with the first failed step.
 */
export function probeRow(probe: string, steps: Step[], run?: string, at = new Date()): Record<string, unknown> {
  const send = steps.find((s) => s.step === "send chat");
  const reply = steps.find((s) => s.step === "reply");
  const failed = steps.find((s) => s.status === "fail");
  const base = { probe, at: at.toISOString().replace(/\.\d+Z$/, "Z"), runner: "github-actions", ...(run ? { run } : {}) };
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

/** The clean-room provider key probe the journey runs on the chat machine after the chat. */
export const KEY_PROBE_PY = fileURLToPath(new URL("./cloud-key-probe.py", import.meta.url));
export const KEY_PROBE_STEP = "clean room: no provider key on the machine";
export type KeyFinding = { place: "env" | "cmdline" | "file"; where: string; what: string };
export type KeyProbe = { as_root: boolean; complete: boolean; gaps: string[]; findings: KeyFinding[]; shipped?: KeyFinding[]; scanned: Record<string, number>; unreadable: string[]; truncated: boolean; ms: number };

/** The probe sent as one exec: as root when sudo asks no password, so it reads every process and home. */
export function keyProbeCommand(source: string, args: string[] = []): string {
  if (source.includes("CMUX_KEY_PROBE")) throw new Error("the probe's source holds its own heredoc delimiter");
  const rest = args.map((a) => ` ${shq(a)}`).join("");
  return `if sudo -n true 2>/dev/null; then p="sudo -n python3"; else p=python3; fi; $p -I -${rest} <<'CMUX_KEY_PROBE'\n${source}\nCMUX_KEY_PROBE`;
}

/** The probe's answer from its `@@keyprobe ` line; throws when the probe printed none. */
export function parseKeyProbe(stdout: string): KeyProbe {
  const line = stdout.split("\n").find((l) => l.startsWith("@@keyprobe "));
  if (!line) throw new Error(`the probe printed no answer: ${stdout.slice(-300)}`);
  const p = JSON.parse(line.slice("@@keyprobe ".length));
  if (!Array.isArray(p?.findings) || typeof p?.complete !== "boolean" || !Array.isArray(p?.gaps)) throw new Error(`the probe's answer has no findings list or coverage: ${line.slice(0, 300)}`);
  return p as KeyProbe;
}

/**
 * The step's result: a finding fails a clean check and is reported otherwise; no finding passes only when the probe
 * read everything (`complete`), since a gap in what it read is "unknown", never "no key".
 */
export function keyProbeStatus(p: KeyProbe, clean: boolean): Status {
  if (p.findings.length || !p.complete) return clean ? "fail" : "skip";
  return "pass";
}

/** The findings, one `place where: what` each, then what the probe could read. Names and places only. */
export function keyProbeDetail(p: KeyProbe): string {
  const s = p.scanned ?? {};
  const cover =
    `${p.as_root ? "as root" : "not as root"}, ${s.processes ?? 0} processes, ${s.files ?? 0} files in ${p.ms} ms; ` +
    (p.complete ? "everything read" : `incomplete: ${p.gaps.join(", ")}`) +
    (p.shipped?.length ? `; ${p.shipped.length} key shape${p.shipped.length > 1 ? "s" : ""} in installed software, not counted` : "");
  if (!p.findings.length) return p.complete ? `no provider key (${cover})` : `no finding, but not everything was read, so unknown (${cover})`;
  const list = p.findings.map((f) => `${f.place} ${f.where}: ${f.what}`);
  return `${p.findings.length} finding${p.findings.length > 1 ? "s" : ""}: ${list.join("; ")} (${cover})`;
}

/** The model stub --model stub runs on the machine. */
/** The shared model stub (tests/fixtures/model-stub, #35332): Anthropic Messages and OpenAI Responses, scripted. */
export const MODEL_STUB_PY = fileURLToPath(new URL("../../tests/fixtures/model-stub/model_stub.py", import.meta.url));
/**
 * The gateway route's time by hop, from each timed call's Server-Timing (a `hop-s` line after its `hop-t` line; the
 * warm-up is dropped), as p50 ms: the Worker's `auth` and `worker-do`, the team object's `do-wait` and `do-gateway`,
 * then per call `object_hop` (worker-do less the object's spans: the hop into the object and back) and `edge`
 * (curl's TTFB less the Worker's spans: the edge and the network to the Worker), and `untimed`, the counted calls
 * without all four spans (the p50s cover only `calls`). Null when no call carried them.
 * Pure, for the tests.
 */
export const hopSpans = (out: string): Record<string, number> | null => {
  const calls: Array<{ ttfb: number; spans: Record<string, number> }> = [];
  for (const line of out.split("\n")) {
    if (line.startsWith("hop-t ")) calls.push({ ttfb: Number(line.split(" ")[2]) * 1000, spans: {} });
    else if (line.startsWith("hop-s ") && calls.length) {
      for (const entry of line.slice(6).split(",")) {
        const m = /^\s*([\w-]+)\s*;\s*dur=([\d.]+)/.exec(entry);
        if (m) calls[calls.length - 1]!.spans[m[1]!] = Number(m[2]);
      }
    }
  }
  const timed = calls.slice(1).filter((c) => ["auth", "worker-do", "do-wait", "do-gateway"].every((k) => k in c.spans));
  if (!timed.length) return null;
  const p50 = (xs: number[]) => Math.round([...xs].sort((x, y) => x - y)[Math.ceil(xs.length / 2) - 1]!);
  const of = (f: (c: { ttfb: number; spans: Record<string, number> }) => number) => p50(timed.map(f));
  return {
    calls: timed.length,
    untimed: calls.length - 1 - timed.length,
    auth: of((c) => c.spans.auth!),
    "worker-do": of((c) => c.spans["worker-do"]!),
    "do-wait": of((c) => c.spans["do-wait"]!),
    "do-gateway": of((c) => c.spans["do-gateway"]!),
    object_hop: of((c) => c.spans["worker-do"]! - c.spans["do-wait"]! - c.spans["do-gateway"]!),
    edge: of((c) => c.ttfb - c.spans.auth! - c.spans["worker-do"]!),
  };
};

/** The model plane every Cloud machine's agents read (web/services/coderouter/vmGuestEnv.ts). */
const VM_MODEL_PLANE_ENV = "/etc/cmux/model-plane.env";
/** Calls timed each way by the gateway hop cost. */
const HOP_SAMPLES = 20;

/**
 * Curl's `hop-t <status> <starttransfer> <total> <exit>` lines (seconds) after the warm-up, as ms percentiles. Every
 * timed call must answer 200 and curl must exit 0 (a transfer cut short can still report 200). Pure, for the tests. (The marker must not start with `@`: curl reads such a `-w` value as a file.)
 */
export const hopTimes = (out: string, n: number): { ttfb_p50: number; ttfb_p90: number; total_p50: number; total_p90: number } => {
  const rows = out.split("\n").filter((l) => l.startsWith("hop-t ")).map((l) => l.split(" "));
  const timed = rows.slice(1);
  if (timed.length !== n) throw new Error(`${timed.length} of ${n} timed calls answered: ${out.slice(-300)}`);
  const bad = timed.filter((r) => r[1] !== "200" || r[4] !== "0");
  if (bad.length) throw new Error(`${bad.length} of ${n} calls did not answer 200 whole (${bad.map((r) => `${r[1]} exit ${r[4] ?? "?"}`).join(", ")})`);
  const pct = (xs: number[], q: number) => {
    const s = [...xs].sort((x, y) => x - y);
    return Math.round(s[Math.min(s.length - 1, Math.ceil(q * s.length) - 1)]! * 1000);
  };
  const ttfb = timed.map((r) => Number(r[2]));
  const total = timed.map((r) => Number(r[3]));
  return { ttfb_p50: pct(ttfb, 0.5), ttfb_p90: pct(ttfb, 0.9), total_p50: pct(total, 0.5), total_p90: pct(total, 0.9) };
};
/**
 * The journey's stub script: one Bash call whose output (printf joins it, so neither the command nor an error that
 * quotes it carries it) the reply then repeats, so the reply shows the tool round trip. A prompt with the chaos leg's
 * counting marker gets the counting turn instead.
 */
export const JOURNEY_STUB_SCRIPT = {
  version: 1,
  steps: [{ shell: "printf '%s-%s\\n' {{nonce}} tool" }, { text: "Stub reply {{nonce}}. The tool printed {{result.0}}." }],
  // The chaos leg's counting turn (cloud-chaos.ts), played only for a prompt that carries its marker.
  turns: [countingTurnScript()],
};

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

/**
 * The guest program that prints the `"model":"..."` of every message in Claude session `id`'s transcript. It
 * searches each Claude directory an agent can run with: CLAUDE_CONFIG_DIR as every running process has it (the
 * launcher's effective one, e.g. ~/.config/cmux/claude-team that agent-auth.sh's team and gateway modes set on a
 * shared machine), then this shell's CLAUDE_CONFIG_DIR, ~/.claude and ~/.config/cmux/claude-team.
 */
export function claudeTranscriptModelsProgram(id: string): string {
  return (
    `id=${shq(id)}; { for e in /proc/[0-9]*/environ; do tr '\\0' '\\n' 2>/dev/null < "$e" | sed -n 's/^CLAUDE_CONFIG_DIR=//p'; done; ` +
    `printf '%s\\n' "\${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude" "$HOME/.config/cmux/claude-team"; } 2>/dev/null | sort -u | ` +
    `while IFS= read -r d; do [ -n "$d" ] || continue; for f in "$d"/projects/*/"$id".jsonl; do ` +
    `[ -f "$f" ] && grep -ho '"model":"[^"]*"' "$f"; done; done | sort -u`
  );
}

/** The models a {@link claudeTranscriptModelsProgram} printout names, `<synthetic>` (Claude Code's own notices) left out. */
export function transcriptModels(stdout: string): string[] {
  return [...new Set([...stdout.matchAll(/"model":"([^"]+)"/g)].map((m) => m[1]!).filter((m) => m !== "<synthetic>"))];
}

/** --machine: stop an earlier run's model stub and drop its endpoint from Claude Code's settings (and Codex's stub provider). */
export const REUSE_RESET =
  // Only the stub an earlier run recorded (its launch writes journey-model-stub.pid), and only while that pid still runs it.
  `p=$(cat /home/cmux/.cmux/journey-model-stub.pid 2>/dev/null); ` +
  `[ -n "$p" ] && grep -qa journey-model-stub.py "/proc/$p/cmdline" 2>/dev/null && kill "$p" 2>/dev/null; ` +
  `rm -f /home/cmux/.cmux/journey-model-stub.*; ` +
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

/**
 * How old a journey's own machine must be before a later run may sweep it: well past the longest job that runs a
 * journey (up to 90 min; cloud-journey.test.ts checks every timeout-minutes in a workflow that runs it to be at most
 * half of this), so a journey that is still running never loses its machine.
 */
export const STALE_JOURNEY_MS = 3 * 3_600_000;
/** And idle this long: a machine with activity since then is in use, whatever its age (a hand run has no timeout). */
export const IDLE_JOURNEY_MS = 60 * 60_000;
export interface StaleMachine { id: string; name: string; status: string; created: string }

/**
 * The machines earlier journey runs meant to delete and left behind (killed or timed out before their cleanup):
 * named `cloud journey auto jr-<tag>` or `cloud journey auto jr-<tag> gateway`, a name only a run that deletes its
 * machine gives, whose tag (`Date.now().toString(36)`, the run's start) is more than `maxAgeMs` old, with no activity
 * in the last IDLE_JOURNEY_MS (`last_active_at`, when the row has it), and not deleted.
 * Ownership is the name, never age or state: a --keep run's `cloud journey jr-<tag>`, any other name, and a tag that
 * does not read as a time are never picked.
 */
export function staleJourneyMachines(rows: any[], nowMs: number, maxAgeMs = STALE_JOURNEY_MS): StaleMachine[] {
  const out: StaleMachine[] = [];
  for (const r of rows) {
    if (!r || r.status === "deleted" || r.status === "deleting") continue;
    const name = typeof r.name === "string" ? r.name : "";
    const m = /^cloud journey auto jr-([0-9a-z]+)( gateway)?$/.exec(name);
    if (!m) continue;
    const started = parseInt(m[1], 36);
    // A real tag is a millisecond time after 2020 and not in the future.
    if (!Number.isFinite(started) || started < Date.UTC(2020, 0, 1) || started > nowMs) continue;
    if (nowMs - started <= maxAgeMs) continue;
    if (typeof r.last_active_at === "number" && nowMs - r.last_active_at <= IDLE_JOURNEY_MS) continue;
    const id = String(r.id ?? r.machine_id ?? "");
    const created = typeof r.created_at === "number" ? new Date(r.created_at).toISOString() : new Date(started).toISOString();
    if (id) out.push({ id, name, status: String(r.status ?? "?"), created });
  }
  return out;
}

/** Every page of cloud.machine.list (`next_cursor`), at most `maxPages` pages. */
export async function listAllMachines(read: (params: Record<string, unknown>) => Promise<any>, maxPages = 20): Promise<any[]> {
  const rows: any[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < maxPages; page++) {
    const v = await read(cursor === null ? { limit: 100 } : { limit: 100, cursor });
    rows.push(...(v?.machines ?? v?.items ?? (Array.isArray(v) ? v : [])));
    cursor = typeof v?.next_cursor === "string" && v.next_cursor ? v.next_cursor : null;
    if (cursor === null) return rows;
  }
  throw new Error(`more than ${maxPages} pages of machines`);
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

/**
 * --machines: the agent test account's machines, one JSON line each, with whether a leaked journey machine may be
 * deleted by the operator's rule (cmux-vm.yml action journey-machines-staging). A journey whose cleanup delete got
 * mutation.indeterminate leaves its `cloud journey jr-*` machine behind, and five of them fill the account's quota.
 * The rule: delete only `cloud journey jr-*` machines (the run's own, or its `gateway`) that are paused or failed, or
 * older than 24 h and not in use; never `cloud journey kept jr-*` (a --keep run's) and never anything else. When the
 * row leaves any doubt, the answer is no, with the reason.
 */
export const JOURNEY_MACHINE_NAME = /^cloud journey jr-[a-z0-9]+( gateway)?$/;
/** A strict machine id (cloud-machine-ops.ts MachineId). */
export const MACHINE_ID = /^vm_[a-z0-9]{20}$/;
const HOUR_MS = 3_600_000;
/** A journey runs well under this (its jobs time out at 45 min), so a younger paused machine may be one in flight. */
const JOURNEY_IN_FLIGHT_MS = HOUR_MS;
/** Activity this recent means the machine is in use. */
const IN_USE_MS = 45 * 60_000;
const OLD_MS = 24 * HOUR_MS;

export function journeyMachineEligible(m: any, now = Date.now()): { eligible: boolean; reason: string } {
  const no = (reason: string) => ({ eligible: false, reason });
  const name = typeof m?.name === "string" ? m.name : "";
  if (!MACHINE_ID.test(String(m?.id ?? ""))) return no("not a machine id");
  if (!JOURNEY_MACHINE_NAME.test(name)) return no(name.startsWith("cloud journey kept ") ? "a kept journey machine" : "not a leaked journey machine's name");
  const created = m?.created_at;
  if (!Number.isSafeInteger(created) || created <= 0 || created > now) return no("no creation time");
  const age = now - created;
  const status = String(m?.status ?? "");
  if (status === "paused" || status === "failed") {
    return age > JOURNEY_IN_FLIGHT_MS ? { eligible: true, reason: status } : no(`${status} but made under 1 h ago: a journey may still be running`);
  }
  if (status !== "running" && status !== "provisioning") return no(`status ${status || "missing"}`);
  if (age <= OLD_MS) return no(`${status} and made under 24 h ago`);
  const last = m?.last_active_at;
  if (last !== null && last !== undefined) {
    if (!Number.isSafeInteger(last) || last <= 0) return no("an unreadable last activity");
    if (now - last <= IN_USE_MS) return no("active in the last 45 min");
  }
  return { eligible: true, reason: `${status}, older than 24 h, ${last ? "idle over 45 min" : "no activity recorded"}` };
}

/**
 * At most this many ids in one run. Each delete is bounded at 5 min (its mutation.indeterminate retries, 180 s, and
 * its read back, 120 s), so 5 fit the workflow job's 35 min with sign-in, the list and the log reads.
 */
export const MAX_DELETE_IDS = 5;

/** One id to delete and the GitHub Actions job whose journey made it and failed to delete it. */
export type DeleteEntry = { id: string; job: string };

/** --delete-ids: `vm_<20>@<job id>` entries, comma or space separated, checked before anything signs in. */
export function parseDeleteEntries(text: string): DeleteEntry[] {
  const raw = [...new Set(text.split(/[\s,]+/).filter(Boolean))];
  if (!raw.length) throw new Error("--delete-ids: no machine ids");
  const bad = raw.filter((e) => !/^vm_[a-z0-9]{20}@[1-9][0-9]{0,19}$/.test(e));
  if (bad.length) throw new Error(`--delete-ids: not vm_<20 lowercase letters or digits>@<GitHub Actions job id>: ${bad.map((b) => JSON.stringify(b.slice(0, 60))).join(", ")}`);
  const entries = raw.map((e) => { const [id, job] = e.split("@"); return { id: id!, job: job! }; });
  const ids = entries.map((e) => e.id);
  const twice = ids.filter((id, i) => ids.indexOf(id) !== i);
  if (twice.length) throw new Error(`--delete-ids: an id given twice: ${twice.join(", ")}`);
  if (entries.length > MAX_DELETE_IDS) throw new Error(`--delete-ids: ${entries.length} ids; at most ${MAX_DELETE_IDS} in one run`);
  return entries;
}

/**
 * The one job whose journey log is trusted as a leak's proof: cmux-vm.yml's deploy-staging (where the journey
 * leaked, job 128746706182), which runs the staging journey through cloud-journey-ci.sh. That script passes only
 * --backend, --out, --cmux or --skip sync, --model and --team, never --keep or --machine (checked 2026-11-09): only
 * hand runs pass --keep, so a machine this job made is never a kept one. A --keep run also never logs a cleanup
 * delete (cleanup returns before it), so the FAIL line is a second proof.
 *
 * The log is trusted only when the job ran this repo's own code on a protected branch: a run of a pull request
 * (a fork's above all), a merge queue or a workflow_run runs code a contributor wrote, which can print any line.
 * So the run's event must be push or workflow_dispatch (deploy-staging's only triggers), its head repository this
 * repo and its head branch feat-cmux-next or main. backend.yml, cloud-journey-pr.yml and cloudflare-relay.yml run
 * the journey on pull requests too, so none of their jobs counts. The jobs API does not say which environment a job
 * ran in; the job name and workflow stand for it (deploy-staging always runs in cmux-vm-staging).
 */
export const PROOF_WORKFLOW = ".github/workflows/cmux-vm.yml";
export const PROOF_JOB = "deploy-staging";
export const PROOF_EVENTS = new Set(["push", "workflow_dispatch"]);
export const PROOF_BRANCHES = new Set(["feat-cmux-next", "main"]);
export const JOURNEY_REPO = "manaflow-ai/cmux";

/**
 * Whether a job's log proves this machine leaked: one journey in it (from its `health` step to the next) logged
 * `PASS create machine <ms> ms :: <id> ...` and then `FAIL delete (cleanup) ...`. Null when proven, else why not.
 * A job runs several journeys (baseline and after a deploy, the test team and the product team), so the create
 * and the failed cleanup must be in the same one.
 */
export function leakProof(log: string, id: string): string | null {
  const lines = log.split("\n").map((l) => l.replace(/\r$/, "").replace(/^\d{4}-\d\d-\d\dT[\d:.]+Z /, ""));
  let inJourney = false;
  let created = false;
  let seenCreate = false;
  for (const line of lines) {
    if (/^(PASS|FAIL) health \d+ ms ::/.test(line)) { inJourney = true; created = false; continue; }
    if (!inJourney) continue;
    const c = /^PASS create machine \d+ ms :: (vm_[a-z0-9]{20})( |$)/.exec(line);
    if (c) { created = c[1] === id; seenCreate ||= created; continue; }
    if (created && /^FAIL delete \(cleanup\) \d+ ms ::/.test(line)) return null;
  }
  return seenCreate ? `the job's journey made ${id} but logged no failed cleanup delete for it` : `the job's log has no journey that made ${id}`;
}

type GhGet = (url: string, headers: Record<string, string>) => Promise<{ status: number; location: string | null; text: string }>;

const ghGet: GhGet = async (url, headers) => {
  const res = await fetch(url, { headers, redirect: "manual", signal: AbortSignal.timeout(60_000) });
  const text = await res.text();
  return { status: res.status, location: res.headers.get("location"), text: text.slice(0, 64 * 1024 * 1024) };
};

/**
 * The GitHub side of the proof: the job is PROOF_JOB of PROOF_WORKFLOW in a trusted run of JOURNEY_REPO (PROOF_EVENTS,
 * its own head repository, PROOF_BRANCHES), and its log has leakProof's two lines. Null when proven, else why not. The log's download link is fetched without the token.
 */
export async function provenLeak(entry: DeleteEntry, token: string, get: GhGet = ghGet): Promise<string | null> {
  const api = `https://api.github.com/repos/${JOURNEY_REPO}/actions`;
  const auth = { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28" };
  const json = async (url: string) => {
    const r = await get(url, auth);
    if (r.status !== 200) throw new Error(`GET ${url.slice(api.length)}: HTTP ${r.status}`);
    return JSON.parse(r.text);
  };
  try {
    const job = await json(`${api}/jobs/${entry.job}`);
    if (String(job?.id) !== entry.job || !Number.isSafeInteger(job?.run_id)) return `job ${entry.job}: not a job of ${JOURNEY_REPO}`;
    if (job.name !== PROOF_JOB) return `job ${entry.job}: ${short(job.name)} is not ${PROOF_JOB}`;
    const run = await json(`${api}/runs/${job.run_id}`);
    if (run?.id !== job.run_id) return `job ${entry.job}: its run did not read back`;
    if (run?.repository?.full_name !== JOURNEY_REPO) return `job ${entry.job}: its run is not in ${JOURNEY_REPO}`;
    if (run?.head_repository?.full_name !== JOURNEY_REPO) return `job ${entry.job}: its run ran code from ${short(run?.head_repository?.full_name)}, not ${JOURNEY_REPO}`;
    if (!PROOF_EVENTS.has(String(run?.event))) return `job ${entry.job}: its run's event ${short(run?.event)} runs code a contributor may have written`;
    if (!PROOF_BRANCHES.has(String(run?.head_branch)) || job.head_branch !== run.head_branch) return `job ${entry.job}: branch ${short(run?.head_branch)} is not feat-cmux-next or main`;
    const workflow = String(run?.path ?? "").replace(/@.*$/, "");
    if (workflow !== PROOF_WORKFLOW) return `job ${entry.job}: workflow ${workflow || "?"} is not ${PROOF_WORKFLOW}`;
    const link = await get(`${api}/jobs/${entry.job}/logs`, auth);
    let log = link.text;
    if (link.status === 302 && link.location) {
      const blob = await get(link.location, {});
      if (blob.status !== 200) return `job ${entry.job}: its log download answered HTTP ${blob.status}`;
      log = blob.text;
    } else if (link.status !== 200) return `job ${entry.job}: its log answered HTTP ${link.status}`;
    const why = leakProof(log, entry.id);
    return why ? `job ${entry.job}: ${why}` : null;
  } catch (e) {
    return `job ${entry.job}: ${(e as Error).message}`;
  }
}

const iso = (ms: unknown) => (Number.isSafeInteger(ms) && (ms as number) > 0 ? new Date(ms as number).toISOString() : null);

/** One --machines line: what the list gives, and the rule's answer. */
export function machineLine(m: any, scope: string, now = Date.now()): Record<string, unknown> {
  const { eligible, reason } = journeyMachineEligible(m, now);
  const created = Number.isSafeInteger(m?.created_at) ? m.created_at : null;
  // A delete needs the job that made it (DeleteEntry); this tool cannot search logs, so it says where to look.
  const findJob = eligible
    ? `the cmux-vm.yml deploy-staging job (a push or dispatch on feat-cmux-next or main) running at ${iso(created)} whose log has "PASS create machine ... :: ${m.id}" and "FAIL delete (cleanup)"; pass ${m.id}@<job id>. No such job (another workflow's journey): this tool cannot delete it`
    : null;
  return {
    scope,
    id: m?.id ?? null,
    name: m?.name ?? null,
    status: m?.status ?? null,
    created: iso(m?.created_at),
    age_h: created ? Math.round(((now - created) / HOUR_MS) * 10) / 10 : null,
    last_active: iso(m?.last_active_at),
    pause_reason: m?.pause_reason ?? null,
    error: m?.error?.code ?? null,
    eligible,
    reason,
    ...(findJob ? { find_job: findJob } : {}),
  };
}

/**
 * A team (null: the account's own) and its API, as the journey calls it. `get` and `remove` give up after
 * `timeoutMs` (the request's own AbortSignal timeout), so a delete's deadline holds across its requests.
 */
export type MachineScope = { scope: string; list(): Promise<any[]>; get(id: string, timeoutMs: number): Promise<any | null>; remove(id: string, key: string, timeoutMs: number): Promise<Answer> };
export type DeleteDeps = { now(): number; sleep(ms: number): Promise<void>; log(line: string): void; retryMs?: number; readBackMs?: number };

/**
 * Delete each id only when a scope's live list has it and the rule allows it. Every id is checked first and one
 * refusal deletes nothing; right before each delete the machine is read again and checked again. Each delete is
 * logged before it is sent, retried under the same idempotency key while the API answers mutation.indeterminate
 * (bounded), then read back until it is gone or deleting (bounded). Returns the ids it could not delete, with why.
 *
 * Each id's whole delete (the read before it, the deletes and their pauses, the read back and its pauses) ends
 * within retryMs + readBackMs (5 min): every request and every pause is cut to the time left, and the deadline is
 * checked before each one, so a slow answer cannot carry it past the bound (the workflow's timeout counts on it).
 */
export async function deleteJourneyMachines(ids: string[], scopes: MachineScope[], runTag: string, deps: DeleteDeps): Promise<{ deleted: string[]; failed: Array<{ id: string; reason: string }> }> {
  const retryMs = deps.retryMs ?? 180_000;
  const readBackMs = deps.readBackMs ?? 120_000;
  const where = new Map<string, MachineScope>();
  const refused: Array<{ id: string; reason: string }> = [];
  const rows = new Map<string, any>();
  for (const s of scopes) for (const m of await s.list()) if (m?.id && !where.has(m.id)) { where.set(m.id, s); rows.set(m.id, m); }
  for (const id of ids) {
    const m = rows.get(id);
    if (!m) { refused.push({ id, reason: "not in the account's machine list" }); continue; }
    const e = journeyMachineEligible(m, deps.now());
    if (!e.eligible) refused.push({ id, reason: `not eligible: ${e.reason} (${m.name ?? "no name"}, ${m.status})` });
  }
  for (const r of refused) deps.log(JSON.stringify({ refused: r.id, reason: r.reason }));
  if (refused.length) return { deleted: [], failed: refused };
  const deleted: string[] = [];
  const failed: Array<{ id: string; reason: string }> = [];
  for (const id of ids) {
    const s = where.get(id)!;
    const fail = (reason: string) => { failed.push({ id, reason }); deps.log(JSON.stringify({ failed: id, reason })); };
    const t0 = deps.now();
    const retryEnd = t0 + retryMs;
    const deadline = retryEnd + readBackMs;
    // Whole milliseconds left before `until`: a request or a pause starts only when at least one is.
    const left = (until: number) => Math.floor(until - deps.now());
    // A request's timeout: its usual one, never past `until`; 0 when no whole millisecond is left (skip it).
    const cut = (until: number, usual: number) => Math.max(0, Math.min(usual, left(until)));
    let m: any;
    const first = cut(retryEnd, 30_000);
    if (first < 1) { fail("read before delete: no time left"); continue; }
    try { m = await s.get(id, first); } catch (e) { fail(`read before delete: ${(e as Error).message}`); continue; }
    const e = m ? journeyMachineEligible(m, deps.now()) : { eligible: false, reason: "gone from the account" };
    if (!m || !e.eligible) { fail(`not eligible at delete time: ${e.reason}`); continue; }
    deps.log(JSON.stringify({ before_delete: id, scope: s.scope, name: m.name, status: m.status, created: iso(m.created_at), last_active: iso(m.last_active_at) }));
    const key = `${runTag}-delete-${id}`;
    const cutOff = (message: string): Answer => ({ status: 0, body: { ok: false, error: { code: "transport", message, retryable: true } } });
    let answer: Answer = cutOff("no delete sent: the read before it used the time");
    for (let attempt = 1; ; attempt++) {
      const budget = cut(retryEnd, 60_000);
      if (budget < 1) break;
      try { answer = await s.remove(id, key, budget); } catch (e) { answer = cutOff((e as Error).message); }
      const again = opRetryable(answer.body) || answer.status === 0;
      const pause = Math.min(5_000 * attempt, 30_000, left(retryEnd));
      if (!again || pause <= 0) break;
      deps.log(JSON.stringify({ retry_delete: id, attempt, error: answer.body?.error?.code ?? null }));
      await deps.sleep(pause);
    }
    const accepted = answer.status === 200 && answer.body?.ok === true;
    const unsure = !accepted && (opRetryable(answer.body) || answer.status === 0);
    // A refusal is final. An answer still cut off after the retries may have deleted it: read back before saying no.
    if (!accepted && !unsure) {
      fail(`delete: HTTP ${answer.status} ${short(answer.body?.error ?? answer.body)}`);
      continue;
    }
    let gone = "";
    for (;;) {
      const budget = cut(deadline, 30_000);
      if (budget < 1) break;
      try {
        const back = await s.get(id, budget);
        if (!back || back.status === "deleting" || back.status === "deleted") { gone = back ? back.status : "gone"; break; }
      } catch { /* read again */ }
      const pause = Math.min(3_000, left(deadline));
      if (pause <= 0) break;
      await deps.sleep(pause);
    }
    if (!gone) {
      fail(`${accepted ? "deleted" : `delete: HTTP ${answer.status} ${short(answer.body?.error ?? answer.body)} after the retries`}, but read back still not gone or deleting by its ${(retryMs + readBackMs) / 1000} s deadline`);
      continue;
    }
    deleted.push(id);
    deps.log(JSON.stringify({ deleted: id, read_back: gone, ...(accepted ? {} : { after: answer.body?.error?.code ?? "transport" }) }));
  }
  return { deleted, failed };
}

/** The Stack password sign-in the journey uses: the agent test account's access token. */
async function passwordSignIn(stack: (typeof STACK)[StackName], email: string, password: string): Promise<{ access: string; refresh: string }> {
  const r = await http("POST", `${STACK_API}/api/v1/auth/password/sign-in`, { email, password }, {
    "x-stack-access-type": "client",
    "x-stack-project-id": stack.project,
    ...(stack.clientKey ? { "x-stack-publishable-client-key": stack.clientKey } : {}),
  });
  if (r.status !== 200 || typeof r.body.access_token !== "string") throw new Error(`Stack sign-in HTTP ${r.status} ${String(r.body.code ?? "")}`);
  return { access: r.body.access_token, refresh: String(r.body.refresh_token ?? "") };
}

async function machinesMode(argv: string[], backend: Backend, email: string | undefined, password: string | undefined, team: string | undefined): Promise<number> {
  const idsArg = argv.includes("--delete-ids") ? argValue("--delete-ids", argv) ?? "" : null;
  // The ids, and each one's proof that a CI journey made it and failed to delete it, are checked before anything
  // signs in. One without its proof deletes nothing.
  const entries = idsArg === null ? null : parseDeleteEntries(idsArg);
  if (entries) {
    const token = process.env.GITHUB_TOKEN ?? "";
    if (!token) throw new Error("--delete-ids needs GITHUB_TOKEN (actions: read on manaflow-ai/cmux) to read each id's journey job");
    let unproven = 0;
    for (const e of entries) {
      const why = await provenLeak(e, token);
      console.log(JSON.stringify(why ? { refused: e.id, job: e.job, reason: why } : { proven: e.id, job: e.job }));
      if (why) unproven++;
    }
    if (unproven) {
      console.log(JSON.stringify({ deleted: 0, not_deleted: entries.length, reason: `${unproven} id(s) without a CI journey's proof of a leak` }));
      return 1;
    }
  }
  const ids = entries?.map((e) => e.id) ?? null;
  const alsoTeams = (argValue("--also-team", argv) ?? "").split(/[\s,]+/).filter(Boolean);
  const secrets: string[] = password ? [password] : [];
  const say = (line: string) => console.log(scrub(line, secrets));
  const signIn = argValue("--sign-in", argv) ?? "password";
  let bearer: string;
  if (signIn === "oidc") bearer = (await oidcSignIn(backend.api, process.env, secrets)).token;
  else {
    if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
    const s = await passwordSignIn(STACK[backend.stack], email, password);
    secrets.push(s.access, s.refresh);
    bearer = s.access;
  }
  const scopes: MachineScope[] = [...new Set([team ?? "", ...alsoTeams])].map((t) => {
    const api = new Api(backend.api, t || undefined);
    api.bearer = bearer;
    return {
      scope: t || "personal",
      list: () => listAllMachines((params) => api.read("cloud.machine.list", params), 50),
      get: async (id, timeoutMs) => {
        try { return await api.read("cloud.machine.get", { machine: id }, timeoutMs); } catch (e) {
          if (/HTTP 404|not[ _.-]?found/i.test(String((e as Error).message))) return null;
          throw e;
        }
      },
      remove: (id, key, timeoutMs) => api.raw("POST", "/v1/ops", { op: "cloud.machine.delete", params: { machine: id }, idempotency_key: key }, timeoutMs),
    };
  });
  const now = Date.now();
  let count = 0;
  for (const s of scopes) {
    for (const m of await s.list()) {
      if (m?.status === "deleted") continue;
      count++;
      say(JSON.stringify(machineLine(m, s.scope, now)));
    }
  }
  say(JSON.stringify({ backend: backend.name, scopes: scopes.map((s) => s.scope), machines: count }));
  if (!ids) return 0;
  const result = await deleteJourneyMachines(ids, scopes, `journey-machines-${Date.now().toString(36)}`, { now: Date.now, sleep, log: say });
  say(JSON.stringify({ deleted: result.deleted.length, not_deleted: result.failed.length }));
  return result.failed.length ? 1 : 0;
}

/** `--delete-kept ID`: one machine a `--keep` run of this account made (`cloud journey jr-...`), read back first. */
async function deleteKeptMode(id: string, backend: Backend, email: string | undefined, password: string | undefined, team: string | undefined, signIn: string): Promise<number> {
  if (!/^vm_[a-z0-9]{20}$/.test(id)) throw new Error(`--delete-kept: not vm_<20 lowercase letters or digits>: ${JSON.stringify(id.slice(0, 60))}`);
  const secrets: string[] = password ? [password] : [];
  const api = new Api(backend.api, team);
  if (signIn === "oidc") api.bearer = (await oidcSignIn(backend.api, process.env, secrets)).token;
  else {
    if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
    api.bearer = (await passwordSignIn(STACK[backend.stack], email, password)).access;
  }
  const m = await api.read("cloud.machine.get", { machine: id });
  const name = String(m?.name ?? "");
  if (!/^cloud journey jr-[a-z0-9]+$/.test(name)) {
    console.log(JSON.stringify({ refused: id, reason: `named ${JSON.stringify(name.slice(0, 60))}, not a --keep journey's machine` }));
    return 1;
  }
  await api.deleteMachine(id, `journey-delete-kept-${id}`);
  console.log(JSON.stringify({ deleted: id, name }));
  return 0;
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
  // --machines (list) and --delete-ids (delete exact ids): the operator's leaked-machine cleanup, no journey.
  if (argv.includes("--machines") || argv.includes("--delete-ids")) return machinesMode(argv, backend, email, password, team);
  // --delete-kept ID: delete one machine a --keep run of this account made (named `cloud journey jr-...`), and nothing else.
  const kept = argValue("--delete-kept", argv);
  if (kept !== undefined) return deleteKeptMode(kept, backend, email, password, team, signIn);
  const cleanupTag = argValue("--cleanup-tag", argv);
  if (cleanupTag !== undefined) return cleanupTagMode(cleanupTag, backend, email, password, team, argv.includes("--kept"));
  const agent = argValue("--agent", argv) ?? "claude";
  const prompt = argValue("--prompt", argv) ?? "Reply with one short sentence that names the planet you are on.";
  const chatBudget = Number(argValue("--chat-timeout", argv) ?? 300) * 1000;
  const cmux = argValue("--cmux", argv);
  // --machine ID: run on that existing machine and keep it (no create, pause, resume or delete).
  const reuse = argValue("--machine", argv);
  const keyedStart = argv.includes("--keyed-start");
  // --desktop-link: the desktop's UDP link readback instead of the chat (needs --cmux for the dial).
  const desktopLink = argv.includes("--desktop-link");
  if (desktopLink && !cmux) throw new Error("--desktop-link needs --cmux PATH: the readback is the CLI's own dial");
  const keep = argv.includes("--keep") || Boolean(reuse);
  // --chaos: after the carrier dial, the chaos leg (cloud-chaos.ts) on this machine; --chaos-probe-out FILE writes it
  // as one synthetic-probe row (--chaos-probe NAME, default cloud-carrier-chaos-<backend>).
  const chaos = argv.includes("--chaos");
  const only = new Set((argValue("--skip", argv) ?? "").split(",").filter(Boolean));
  if (reuse) only.add("pause");
  // --model stub: the model endpoint is the only stand-in (the shared model stub on the machine). The login the
  // journey passes is then a made-up setup-token shape: the stub checks it arrived, and no real credential exists.
  const modelStub = argValue("--model", argv) === "stub";
  const gatewayCmux = argValue("--gateway", argv);
  const gatewayLocal = argValue("--gateway-local", argv);
  const gatewayUpstream = argValue("--gateway-upstream", argv) ?? "stub";
  if (gatewayCmux && gatewayLocal) throw new Error("--gateway and --gateway-local: pick one");
  if (gatewayLocal && gatewayUpstream === "stub") throw new Error("--gateway-local needs --gateway-upstream URL (the person's proxy, reachable from this computer)");
  const gatewayAny = Boolean(gatewayCmux || gatewayLocal);
  // The clean room fails on a finding when the chat machine is meant to hold no key; otherwise it reports.
  const keysClean = gatewayAny || argv.includes("--keys-clean");
  const keysProbeOut = argValue("--keys-probe-out", argv);
  // With the gateway and the stub, the stub's nonce reply is checked as --model stub does, but it runs on the gateway.
  const gatewayStub = Boolean(gatewayCmux) && gatewayUpstream === "stub";
  const nonce = randomBytes(6).toString("hex");
  const claudeLogin = modelStub
    ? `sk-ant-oat01-journeystub-${randomBytes(24).toString("hex")}`
    : (process.env.CLAUDE_CODE_OAUTH_TOKEN || creds.CLAUDE_CODE_OAUTH_TOKEN || "").trim();
  // Codex's login is its auth.json (a ChatGPT sign-in), as the app copies it; CODEX_AUTH_JSON for a real run.
  const codexLogin = modelStub ? stubCodexAuth() : (process.env.CODEX_AUTH_JSON || creds.CODEX_AUTH_JSON || "").trim();
  // `claude/claude-sonnet-5-5` is the claude harness on that model (`acp ensure -m`): the same login and lifecycle legs.
  const harness = agent.split("/")[0];
  const provider: "claude" | "codex" | undefined = harness === "claude" || harness === "codex" ? harness : undefined;
  const askedModel = agent.includes("/") ? agent.slice(agent.indexOf("/") + 1) : "";
  const login = provider === "codex" ? codexLogin : provider === "claude" ? claudeLogin : "";
  const loginStep = provider === "codex" ? "pass Codex login" : "pass Claude login";
  const probeOut = argValue("--probe-out", argv);
  const probeName = argValue("--probe", argv) ?? `cloud-chat-replies-${backend.name === "prod" ? "production" : backend.name}`;
  const tag = `jr-${Date.now().toString(36)}`;
  // A run that deletes its machine at the end names it "cloud journey auto jr-...": only those names are the sweep's
  // (the run meant to delete them). A --keep run keeps the plain "cloud journey jr-..." name, as every run used before
  // the sweep existed, and the sweep never matches it, so a kept machine is never deleted.
  const machineName = keep ? `cloud journey ${tag}` : `cloud journey auto ${tag}`;
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
  let gatewayMachine: string | null = null;
  // The team's gateway mode before this run changed it, the API that set it, and the local gateway this run started.
  let gatewayModeBefore: string | null = null;
  let gatewayMachineBefore: string | null = null;
  let gatewayApi: Api | null = null;
  let localGateway: ReturnType<typeof spawn> | null = null;
  let localGatewayDir: string | null = null;
  let deleted = false;
  let cleaned = false;
  // Delete what this run made, pass, fail or cancel. A create whose reply was lost leaves `machine`
  // null, so the run's own machine is also found by its name (`cloud journey <tag>`).
  const cleanup = async () => {
    if (localGateway?.pid) {
      // Only the process this run started, by its own pid.
      try { process.kill(localGateway.pid, "SIGTERM"); } catch {}
      localGateway = null;
    }
    if (localGatewayDir) {
      // The gateway's log (machine ids, paths and statuses; never a token) stays with the run's evidence.
      try { if (outDir) writeFileSync(path.join(outDir, "gateway.log"), scrub(readFileSync(path.join(localGatewayDir, "gateway.log"), "utf8"), J.secrets)); } catch {}
      rmSync(localGatewayDir, { recursive: true, force: true });
      localGatewayDir = null;
    }
    // The team's gateway mode comes back even with --keep: the gateway this run used is gone (or about to be).
    if (gatewayModeBefore && gatewayApi) {
      const before = gatewayModeBefore;
      const beforeMachine = gatewayMachineBefore;
      gatewayModeBefore = null;
      await J.step("team gateway mode restored (cleanup)", async () => {
        const r = await gatewayApi!.raw("PUT", "/v1/cloud/inference-gateway", { mode: before, machine: beforeMachine });
        if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
        return { value: null, detail: before };
      }).catch(() => undefined);
    }
    if (cleaned || keep || !api.bearer) return;
    cleaned = true;
    if (gatewayMachine) {
      const g: string = gatewayMachine;
      await J.step("delete gateway machine (cleanup)", async () => {
        await api.deleteMachine(g, `${tag}-gw-delete`);
        return { value: null, detail: g };
      }).catch(() => undefined);
    }
    if (deleted) return;
    let id = machine;
    if (!id) {
      const v = await api.read("cloud.machine.list", {}).catch(() => null);
      const rows: any[] = v?.machines ?? v?.items ?? (Array.isArray(v) ? v : []);
      id = rows.find((r) => r?.name === machineName && r.status !== "deleted")?.id ?? null;
    }
    if (!id) return;
    const target: string = id;
    await J.step("delete (cleanup)", async () => {
      await api.deleteMachine(target, `${tag}-cleanup-delete`);
      return { value: null, detail: target };
    }).catch(() => undefined);
  };
  // The cmuxterm-hq probes.py row: ok with send-to-reply ms, or fail naming the first failed step (or none reached).
  const writeProbe = () => {
    if (probeOut) writeFileSync(probeOut, `${JSON.stringify(probeRow(probeName, J.steps, process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : undefined))}\n`);
  };
  // A job cancel or timeout sends SIGTERM, which skips `finally`: clean up, write results, exit.
  const onSignal = (signal: string) => {
    for (const dial of carrierDials) dial.kill("SIGTERM");
    for (const dir of carrierStateDirs) rmSync(dir, { recursive: true, force: true });
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
      const s = await passwordSignIn(stack, email!, password!);
      J.secrets.push(s.access, s.refresh);
      return { value: s.access, detail: `Stack project ${stack.project.slice(0, 8)}` };
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

    if (gatewayAny) {
      gatewayApi = installApi;
      await J.step("team in gateway mode", async () => {
        const g = await installApi.raw("GET", "/v1/cloud/inference-gateway");
        if (g.status !== 200) throw new Error(`GET HTTP ${g.status} ${short(g.body?.error ?? g.body)}`);
        const before = String(g.body?.gateway?.mode ?? "off");
        const beforeMachine = typeof g.body?.gateway?.machine === "string" ? g.body.gateway.machine : null;
        const r = await installApi.raw("PUT", "/v1/cloud/inference-gateway", { mode: "gateway", machine: null });
        if (r.status !== 200) throw new Error(`PUT HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
        gatewayModeBefore = before;
        gatewayMachineBefore = beforeMachine;
        return { value: null, detail: `was ${before}; set before the chat machine is made, so its edge route goes to the gateway` };
      });
    }
    if (!keep) {
      // Machines that killed or timed-out runs left behind hold the account's quota (cloud.quota.exceeded at create).
      // A sweep error never fails the journey: the step is recorded as skipped with the error, and create goes on.
      const name = "sweep leaked journey machines";
      const t0 = Date.now();
      const err = (e: unknown) => String((e as Error)?.message ?? e).slice(0, 300);
      try {
        const rows = await listAllMachines((params) => api.read("cloud.machine.list", params));
        const stale = staleJourneyMachines(rows, Date.now());
        const failed: string[] = [];
        for (const m of stale) {
          // Each row is logged before its delete, so a wrong pick can be traced to the machine it took.
          console.log(`sweep: deleting ${m.id} "${m.name}" status ${m.status} created ${m.created}`);
          await api.deleteMachine(m.id, `${tag}-sweep-${m.id}`).catch((e) => failed.push(`${m.id}: ${err(e)}`));
        }
        const detail = `${stale.length - failed.length} of ${stale.length} leaked deleted (${rows.length} machines)${stale.length ? `: ${stale.map((m) => m.id).join(", ")}` : ""}${failed.length ? `; failed ${failed.join("; ")}` : ""}`;
        J.record({ step: name, status: failed.length ? "skip" : "pass", ms: Date.now() - t0, detail });
      } catch (e) {
        J.record({ step: name, status: "skip", ms: Date.now() - t0, detail: `list failed: ${err(e)}` });
      }
    }
    let createAnsweredAt: number | null = null;
    let createSentAt: number | null = null;
    const created = reuse
      ? await J.step("use machine", async () => {
          const m = await api.read("cloud.machine.get", { machine: reuse });
          if (m.status === "paused") await api.op("cloud.machine.start", { machine: reuse }, `${tag}-wake`);
          return { value: m, detail: `${reuse} status ${m.status}${m.status === "paused" ? " (started)" : ""}, kept` };
        })
      : await J.step("create machine", async () => {
          createSentAt = Date.now();
          const v = await api.op("cloud.machine.create", { name: machineName, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${tag}-create`);
          machine = v.machine.id as string;
          createAnsweredAt = Date.now();
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

    if (desktopLink) {
      // The team the platform decides rd_link for: --team, else the account's personal team (user.ensure).
      const acting = team ?? (typeof user?.personal_team === "string" ? user.personal_team : null);
      const named = teamIdsIn(user, created, bound);
      console.log(`desktop link: team ${acting ?? "?"} (team ids named by user.ensure and the machine: ${named.join(", ") || "none"})`);
      J.record({ step: "desktop link: account team", status: acting ? "pass" : "skip", ms: 0, detail: `${acting ?? "not named"}; named: ${named.join(", ") || "none"}` });
      await J.step("desktop link (carrier dial --service desktop)", async () => {
        let run: DesktopLinkRun | null = null;
        // A desktop that is not up yet (a refused or failed dial with no link note) gets two more tries.
        for (let attempt = 1; attempt <= 3; attempt++) {
          run = await desktopLinkDial(cmux!, api, created.id);
          if (run.lines.length || !run.error) break;
          console.log(`desktop link: attempt ${attempt}: ${run.error}`);
          if (attempt < 3) await sleep(10_000);
        }
        const r = run!;
        const lines = r.lines.map(maskAddresses);
        for (const l of lines) console.log(l);
        const verdict = desktopLinkVerdict(r.lines);
        if (outDir) {
          writeFileSync(path.join(outDir, "desktop-link.json"), `${JSON.stringify({
            api: backend.api,
            backend: backend.name,
            machine: created.id,
            team: acting,
            team_ids_named: named,
            status: r.status,
            error: r.error,
            controls: r.controls.slice(0, 20),
            datagrams: r.datagrams,
            ms: r.ms,
            lines,
            up: verdict.up,
            why: verdict.why,
            // rd_link.rs logs `up` with no candidate pair: which path won (direct or STUN srflx) is not in the CLI's log.
            path: "not logged by cmux carrier dial (its `up` note names no candidate pair)",
          }, null, 2)}\n`);
        }
        if (!verdict.up) throw new Error(`${verdict.why}${r.error ? ` (${r.error})` : ""}; controls ${r.controls.slice(0, 8).join(", ") || "none"}`);
        return { value: null, detail: `${verdict.why}; ${lines.length} desktop_link lines, ${r.datagrams} datagrams, controls ${r.controls.slice(0, 8).join(", ")}, ${r.ms} ms` };
      }).catch(() => undefined);
      // The host's side, if its journal says more about the link (cmux-agent-rd.service); never fails the run.
      const t0 = Date.now();
      const journal = await exec(`{ sudo -n journalctl -u cmux-agent-rd.service --no-pager -o cat --since '15 min ago' 2>/dev/null || journalctl -u cmux-agent-rd.service --no-pager -o cat --since '15 min ago' 2>&1; } | grep -iE 'link|stun|srflx|candidate|udp' | tail -n 20`).catch((e: Error) => ({ code: -1, stdout: "", stderr: e.message }));
      const hostLines = maskAddresses(journal.stdout.trim()).split("\n").filter(Boolean);
      for (const l of hostLines) console.log(`host: ${l}`);
      J.record({ step: "desktop link: host journal", status: "skip", ms: Date.now() - t0, detail: hostLines.join("; ").slice(0, 900) || `no link lines (exit ${journal.code} ${journal.stderr.slice(-200)})` });
      // The readback is the whole run: the machine is deleted by the cleanup below.
      throw new Error("desktop link readback done");
    }

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

    const gwLog = "/home/cmux/.cache/cmux/inference-gateway.log";
    const gwStubLog = "/home/cmux/.cmux/gateway-proxy-stub.log";
    let gwExec: Exec | null = null;
    // The stub's URL on the gateway machine (--gateway with the stub), for the hop cost.
    let gwStubUrl: string | null = null;
    if (gatewayCmux) {
      const g = await J.step("gateway machine", async () => {
        const v = await api.op("cloud.machine.create", { name: `${machineName} gateway`, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${tag}-gw-create`);
        gatewayMachine = v.machine.id as string;
        const m = await waitMachine(api, gatewayMachine, (x) => x.status === "running" && Boolean(x.host), 300_000);
        return { value: m, detail: `${gatewayMachine}, daemon ${m.image?.daemon_version ?? "?"}` };
      });
      gwExec = directExec(api, g.id, J);
      let upstream = gatewayUpstream;
      if (gatewayStub) {
        // The person's own proxy, as they would run it on their gateway machine: here the shared model stub.
        upstream = await J.step("the person's proxy on the gateway machine (stub)", async () => {
          const file = "/home/cmux/.cmux/gateway-proxy-stub.py";
          const script = "/home/cmux/.cmux/gateway-proxy-stub.json";
          const ready = "/home/cmux/.cmux/gateway-proxy-stub.ready";
          for (const [p, data] of [[file, readFileSync(MODEL_STUB_PY)], [script, Buffer.from(JSON.stringify(JOURNEY_STUB_SCRIPT))]] as const) {
            const w = await api.raw("POST", `/v1/cloud/machines/${g.id}/fs/write`, { path: p, dataBase64: data.toString("base64"), mode: 0o644 });
            if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${p}: HTTP ${w.status} ${short(w.body?.error?.code ?? "")}`);
          }
          const r = await gwExec!(
            `mkdir -p /home/cmux/.cmux; rm -f ${shq(gwStubLog)} ${shq(ready)}; (nohup python3 ${shq(file)} --port 0 --script ${shq(script)} --nonce ${shq(nonce)} --log ${shq(gwStubLog)} --ready-file ${shq(ready)} >${shq(gwStubLog)}.out 2>&1 &); ` +
              `for i in $(seq 50); do [ -s ${shq(ready)} ] && break; sleep 0.2; done; ` +
              `port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' ${shq(ready)} 2>/dev/null); ` +
              `[ -n "$port" ] && echo "@@port $port" || { echo stub-down; tail -5 ${shq(gwStubLog)}.out; exit 1; }`,
          );
          const port = /@@port (\d+)/.exec(r.stdout)?.[1];
          if (!port) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)}`);
          return { value: `http://127.0.0.1:${port}`, detail: `the model stub at 127.0.0.1:${port} on the gateway machine, nonce ${nonce}` };
        });
        gwStubUrl = upstream;
      }
      await J.step("cmux inference setup (gateway machine)", async () => {
        const dir = mkdtempSync(path.join(tmpdir(), "cmux-gw-"));
        const tokenFile = path.join(dir, "token");
        writeFileSync(tokenFile, install.token, { mode: 0o600 });
        try {
          const args = ["inference", "setup", "--machine", created.id, "--gateway-machine", g.id, "--upstream", upstream, "--path", "gateway", "--api", backend.api, "--token-file", tokenFile];
          if (team) args.push("--team", team);
          const r = spawnSync(gatewayCmux, args, { encoding: "utf8", timeout: 600_000, env: { PATH: process.env.PATH ?? "", HOME: dir } });
          const out = scrub(`${r.stdout ?? ""}${r.stderr ?? ""}`, J.secrets);
          if (r.status !== 0 || !out.includes("Path: gateway")) throw new Error(`exit ${r.status}: ${headTail(out)}`);
          return { value: null, detail: out.trim().split("\n").filter((l) => l.startsWith("Path:") || l.startsWith("This machine")).join(" ").slice(0, 300) };
        } finally {
          rmSync(dir, { recursive: true, force: true });
        }
      });
    }

    if (gatewayLocal) {
      await J.step("cmux inference gateway (this computer)", async () => {
        const dir = mkdtempSync(path.join(tmpdir(), "cmux-gw-local-"));
        localGatewayDir = dir;
        const tokenFile = path.join(dir, "token");
        writeFileSync(tokenFile, install.token, { mode: 0o600 });
        const log = path.join(dir, "gateway.log");
        const args = ["inference", "gateway", "--api", backend.api, "--upstream", gatewayUpstream, "--token-file", tokenFile];
        if (team) args.push("--team", team);
        const out = openSync(log, "a");
        const child = spawn(gatewayLocal, args, { stdio: ["ignore", out, out], env: { PATH: process.env.PATH ?? "", HOME: dir } });
        localGateway = child;
        closeSync(out);
        const t0 = Date.now();
        while (Date.now() - t0 < 60_000) {
          const g = await installApi.raw("GET", "/v1/cloud/inference-gateway");
          if (g.body?.gateway?.online === true) return { value: null, detail: `online in ${Math.round((Date.now() - t0) / 1000)} s, in front of ${gatewayUpstream}` };
          if (child.exitCode !== null) break;
          await sleep(1_000);
        }
        throw new Error(`the gateway did not come online: ${scrub(readFileSync(log, "utf8"), J.secrets).slice(-600)}`);
      });
      await J.step("cmux inference setup (this computer's gateway)", async () => {
        const dir = mkdtempSync(path.join(tmpdir(), "cmux-gw-"));
        const tokenFile = path.join(dir, "token");
        writeFileSync(tokenFile, install.token, { mode: 0o600 });
        try {
          const args = ["inference", "setup", "--machine", created.id, "--path", "gateway", "--api", backend.api, "--token-file", tokenFile];
          if (team) args.push("--team", team);
          const r = spawnSync(gatewayLocal, args, { encoding: "utf8", timeout: 600_000, env: { PATH: process.env.PATH ?? "", HOME: dir } });
          const out = scrub(`${r.stdout ?? ""}${r.stderr ?? ""}`, J.secrets);
          if (r.status !== 0 || !out.includes("Path: gateway")) throw new Error(`exit ${r.status}: ${headTail(out)}`);
          return { value: null, detail: out.trim().split("\n").filter((l) => l.startsWith("Path:") || l.startsWith("This machine")).join(" ").slice(0, 300) };
        } finally {
          rmSync(dir, { recursive: true, force: true });
        }
      });
    }

    if (gatewayAny) {
      J.skip(loginStep, "--gateway: the chat machine gets no login; its model calls go to the team's gateway");
    } else if (!provider || only.has("chat") || only.has("login")) {
      J.skip(loginStep, !provider ? `agent ${agent}` : "--skip");
    } else if (!login) {
      J.skip(loginStep, provider === "codex" ? "no CODEX_AUTH_JSON: the reply needs the person's Codex login on the machine" : "no CLAUDE_CODE_OAUTH_TOKEN: the reply needs the person's Claude login on the machine");
    } else {
      // CloudCredentialTransfer.perform on a Worker machines client: preflight (which also makes and checks the staging
      // folder as the work user), stage (fs/write as root puts the file in 0644), install, each through the routes the app uses.
      await J.step(loginStep, async () => {
        if (!validLogin(provider, login)) throw new Error(provider === "codex" ? "CODEX_AUTH_JSON is not a Codex ChatGPT sign-in (auth.json with tokens)" : "CLAUDE_CODE_OAUTH_TOKEN is not a `claude setup-token` login");
        // On a team machine the journey is its creator and copies as a DEV or nightly build does (Release copies
        // only to an owner machine).
        const programs = loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), provider, Boolean(team));
        const pre = await waitPreflight(exec, programs.preflight, team ? "owner or team" : "owner");
        const folder = "/home/cmux/.cmux/credential-transfer"; // made and checked by the preflight that just passed
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

    if (gatewayStub && provider === "codex" && !only.has("chat")) {
      // The stub lists no models, and with the image's default model slug Codex sends it no tools (codex-cli 0.164
      // against the stub: tools=0 with the default, 9 with "stub-model"), so the turn gets the stub's side reply
      // (gateway-e2e runs 7 and 8). Name the stub's model, as the --model stub path does; the provider stays the
      // image's `cmux` (edge, placeholder key), so the call still goes through the gateway.
      await J.step("Codex names the stub's model", async () => {
        const r = await exec(
          `bash -lc true >/dev/null 2>&1 </dev/null; f=/home/cmux/.codex/config.toml; ` +
            `python3 -I - "$f" <<'PY'\nimport pathlib, re, sys\np = pathlib.Path(sys.argv[1])\nlines = p.read_text().splitlines() if p.exists() else []\n` +
            `head = next((i for i, l in enumerate(lines) if re.match(r"\\s*\\[", l)), len(lines))\n` +
            `lines = [l for i, l in enumerate(lines) if i >= head or not re.match(r"\\s*model\\s*=", l)]\n` +
            `p.write_text("\\n".join(['model = "stub-model"'] + lines) + "\\n")\nPY\n` +
            `grep -q '^model = "stub-model"' "$f" && grep -q '^model_provider = "cmux"' "$f" && echo model-set`,
        );
        if (!r.stdout.includes("model-set")) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
        return { value: null, detail: 'model = "stub-model"; model_provider stays "cmux" (the edge, the placeholder key)' };
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
        const pidFile = "/home/cmux/.cmux/journey-model-stub.pid";
        for (const [path, data] of [[file, readFileSync(MODEL_STUB_PY)], [script, Buffer.from(JSON.stringify(JOURNEY_STUB_SCRIPT))]] as const) {
          const w = await api.raw("POST", `/v1/cloud/machines/${created.id}/fs/write`, { path, dataBase64: data.toString("base64"), mode: 0o644 });
          if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${path}: HTTP ${w.status} ${short(w.body?.error?.code ?? "")}`);
        }
        // Port 0: the stub binds a free port and writes it to the ready file.
        const point = provider === "codex"
          ? `python3 - "$port" <<'PY'\n${CODEX_STUB_CONFIG}\nPY`
          : `python3 - "$port" <<'PY'\nimport json, pathlib, sys\np = pathlib.Path('/home/cmux/.claude/settings.json')\nc = json.loads(p.read_text()) if p.exists() else {}\nc.setdefault('env', {})['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + sys.argv[1]\np.write_text(json.dumps(c))\nprint('stub-ready')\nPY`;
        const r = await exec(
          `rm -f ${shq(stubLog)} ${shq(ready)} ${shq(pidFile)}; (nohup python3 ${shq(file)} --port 0 --script ${shq(script)} --nonce ${shq(nonce)} --log ${shq(stubLog)} --ready-file ${shq(ready)} >${shq(stubLog)}.out 2>&1 & echo $! >${shq(pidFile)}); ` +
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
    // One turn's reply: the session's last message once `acp wait` says the turn ended, or the turn's own error.
    const awaitReply = async (): Promise<string> => {
      const t0 = Date.now();
      let last = "";
      while (Date.now() - t0 < chatBudget) {
        const r = await exec(`${GUEST}"$c" acp wait ${shq(session)} --timeout 20 >/dev/null 2>&1; echo "@@wait $?"; "$c" acp last ${shq(session)} 2>&1; echo "@@lastexit $?"`, 45_000);
        const wait = /@@wait (\d+)/.exec(r.stdout)?.[1];
        last = r.stdout.replace(/@@wait \d+\n?/, "").replace(/@@lastexit \d+\s*$/, "").trim();
        if (wait === "0" && last) return last;
        if (wait === "2") throw new Error(`the agent waits on a permission: ${last.slice(-200)}`);
        if (wait && wait !== "3" && wait !== "0") {
          // A failed turn (exit 1) prints no reply: name its error, e.g. a harness with no sign-in on the machine.
          const h = await exec(`${GUEST}"$c" acp tail ${shq(session)} 2>&1 | grep -E '"kind":"turn_error"' | tail -1`, 45_000).catch(() => null);
          const why = /"error":"((?:[^"\\]|\\.)*)"/.exec(h?.stdout ?? "")?.[1] ?? "";
          throw new Error(`acp wait exit ${wait}: ${(why || last).slice(-300)}`);
        }
      }
      throw new Error(`no reply within ${chatBudget / 1000} s; last: ${last.slice(-300)}`);
    };
    const send = async (text: string) => {
      const r = await exec(`${GUEST}printf '%s' ${shq(text)} | "$c" acp send --no-wait ${shq(session)} - 2>&1; echo "@@exit $?"`, 60_000);
      if (!/@@exit 0/.test(r.stdout)) throw new Error(r.stdout.slice(-400) || r.stderr.slice(-400));
    };
    // The model requests the stub logged for real turns (streamed, not a title or topic side request).
    const stubTurns = async (): Promise<any[]> => {
      const r = await exec(`cat ${shq(stubLog)} 2>/dev/null`);
      return r.stdout.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } })
        .filter((x: any) => x && x.method === "POST" && x.stream && !x.side);
    };
    // A later turn in the same session. With the stub, a request's step is the number of tool results already in the
    // conversation: the first request of this turn at step >= 1 proves the session still holds turn 1 (its tool
    // result), where a fresh conversation would start at step 0.
    // `send --no-wait` returns once the prompt is queued, so `acp wait` right after it can still see the session idle
    // and `acp last` would read the previous turn's reply. Each later turn's prompt starts with its own marker, and its
    // reply is read only once `acp history` lists a turn with that prompt (the turn started; history keeps a prompt's
    // first 120 characters). `acp wait --match` cannot see it: it leaves the person's own prompts out.
    let turns = 0;
    const turnStarted = async (marker: string) => {
      const t0 = Date.now();
      while (Date.now() - t0 < chatBudget) {
        const r = await exec(`${GUEST}"$c" acp --json history ${shq(session)} --limit 5 2>&1`, 45_000);
        let listed: any[] = [];
        try { listed = JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))).turns ?? []; } catch { /* not yet readable */ }
        if (listed.some((t: any) => typeof t?.prompt === "string" && t.prompt.startsWith(marker))) return;
        await sleep(2_000);
      }
      throw new Error(`the turn's prompt did not reach the session within ${chatBudget / 1000} s`);
    };
    const laterTurn = async (text: string): Promise<{ value: null; detail: string }> => {
      const before = modelStub ? (await stubTurns()).length : 0;
      const marker = `[journey turn ${tag}-${++turns}]`;
      await send(`${marker} ${text}`);
      await turnStarted(marker);
      const last = await awaitReply();
      if (!modelStub) return { value: null, detail: last.slice(0, 280) };
      if (!last.includes(`Stub reply ${nonce}.`)) throw new Error(`the reply does not carry the stub's nonce ${nonce}: ${last.slice(-200)}`);
      const fresh = (await stubTurns()).slice(before);
      if (!fresh.length) throw new Error("the reply came back but the stub logged no model request for this turn");
      if (!(fresh[0].step >= 1)) throw new Error(`this turn's first model request is at step ${fresh[0].step}: the session lost the earlier turns`);
      return { value: null, detail: `${last.slice(0, 120)} (model request at step ${fresh[0].step}: the earlier turns came along)` };
    };
    // An agent with no login to pass (OpenCode on its free Zen models) gets the later turns with --lifecycle.
    const lifecycle = (provider || argv.includes("--lifecycle")) && !gatewayAny && !only.has("chat") && !only.has("lifecycle");
    if (only.has("chat")) {
      J.skip("start agent", "--skip chat");
    } else {
      await J.step(`start agent (${agent})`, async () => {
        const r = await exec(`${GUEST}"$c" acp ensure ${shq(session)} -m ${shq(agent)} --json 2>&1; echo "@@exit $?"`, 120_000);
        if (!/@@exit 0/.test(r.stdout)) throw new Error(r.stdout.slice(-400) || r.stderr.slice(-400));
        return { value: null, detail: `session ${session}` };
      });
      await J.step("send chat", async () => {
        await send(prompt);
        return { value: null, detail: prompt.slice(0, 80) };
      });
      await J.step("reply", async () => {
        const last = await awaitReply().catch(async (e: Error) => {
          // Through a gateway, or any Codex chat (the model-plane route a Codex chat with no login of its own takes):
          // say what the machine's Codex had to reach its model with, never only "no reply" (cloud chat matrix, 11-10).
          if (!gwExec && !gatewayLocal && provider !== "codex") throw e;
          // Through a gateway, what the chat machine's Codex had to reach the edge with: the model-plane files, the
          // machine kind and Codex's auth choice, the provider its config names, and whether a login shell and the
          // daemon carry the edge's base URL and key (the base URL as edge, other or unset; the key as set or not).
          const probe = [
            `ls /etc/cmux/model-plane.env "$HOME/.config/cmux/model-plane.env" /etc/profile.d/cmux-agents.sh 2>&1 | tr '\\n' ' '`,
            `echo "kind=$(cat /etc/cmux/vm-kind 2>/dev/null) codex-auth=$(cat "$HOME/.config/cmux/agent-auth/codex" 2>/dev/null)"`,
            `grep -nE '^(model_provider|profile) *=|^\\[model_providers' "$HOME/.codex/config.toml" 2>&1 | tr '\\n' ' '`,
            `bash -lc 'case "\${OPENAI_BASE_URL-}" in https://coderouter.cmux.internal*) b=edge ;; "") b=unset ;; *) b=other ;; esac; echo "login-shell: base=$b key=\${OPENAI_API_KEY:+set}"' 2>&1 | tail -1`,
            // acpmux reads the login shell with a 3 s limit and caches only the names of secret values: how long the
            // shell takes here, and what the daemon's login-env cache says (names and age only), show which side lost it.
            `s=$(date +%s%N); bash -l -i -c true >/dev/null 2>&1 < /dev/null; echo "login-shell-ms=$(( ($(date +%s%N) - s) / 1000000 ))"`,
            `for f in "$HOME/.acpmux/login-env.json" "$HOME/.cmux/acpmux/login-env.json"; do [ -f "$f" ] && python3 -I -c 'import json,sys,time; d=json.load(open(sys.argv[1])); print(sys.argv[1], "age_s=%s" % (int(time.time()) - int(d.get("savedAt") or 0)), "secret_names=%s" % ",".join(d.get("secretNames") or []))' "$f" 2>&1; done`,
            `grep -hoE '(login shell env|login env|imported login shell environment)[^"]{0,160}' "$HOME"/.acpmux/daemon.log "$HOME"/.cmux/acpmux/daemon.log 2>/dev/null | tail -3`,
            `for p in $(pgrep -u "$(id -u)" -f 'cmux-tui|acpmux' | head -3); do echo "pid $p: $(tr '\\0' '\\n' < /proc/$p/environ 2>/dev/null | grep -E '^OPENAI_(BASE_URL|API_KEY)=' | sed 's/=.*/=set/' | tr '\\n' ' ')"; done`,
            // The model plane itself, from the machine: status and time only, one bounded request each (a hung edge
            // reads as 000 after 15 s), with the machine's own base URL and key, never printed.
            `bash -lc 'm=$(grep -m1 -E "^model *=" "$HOME/.codex/config.toml" | cut -d\\" -f2); echo "codex model: \${m:-unset}"; for p in models responses; do if [ "$p" = models ]; then a=(); else a=(-H "content-type: application/json" -d "{\\"model\\":\\"\${m:-gpt-5}\\",\\"input\\":\\"ping\\"}"); fi; echo "edge $p: $(curl -sS -m 15 -o /dev/null -w "%{http_code} %{time_total}s" -H "authorization: Bearer \${OPENAI_API_KEY}" "\${a[@]}" "\${OPENAI_BASE_URL%/}/$p" 2>&1 | tail -c 160)"; done' 2>&1 | tail -3`,
            // Which codex the chat runs, and what the image's auth rules (agent-auth.sh) would pick for it here.
            `echo "codex: $(command -v codex) launcher=$([ -x /etc/cmux/codex ] && echo yes || echo no) running=$(ps -o args= -u "$(id -u)" | grep -E '(^|/)codex( |$)' | grep -v grep | head -1 | cut -c1-120)"`,
            `bash -lc '[ -f /etc/cmux/agent-auth.sh ] && . /etc/cmux/agent-auth.sh && cmux_agent_auth_resolve codex && echo "agent-auth codex: $cmux_agent_auth_mode ($cmux_agent_auth_reason)"' 2>&1 | tail -1`,
            // The session's own account of the turn: its last error or retry line (no prompt or reply text).
            `${GUEST}"$c" acp tail ${shq(session)} 2>&1 | grep -oE '"kind":"(turn_error|retry|error|status)"[^}]{0,300}' | tail -3`,
          ].join("; ");
          const d = await exec(probe).catch(() => null);
          throw new Error(`${e.message} (the chat machine: ${(d?.stdout ?? "unread").replace(/\n/g, "; ").slice(0, 1500)})`);
        });
        // The stub repeats the Bash output in its reply, so this also proves the tool ran and its output came back.
        if ((modelStub || gatewayStub) && !last.includes(`Stub reply ${nonce}. The tool printed ${nonce}-tool`)) {
          // Through the gateway, what the stub was sent: each request's path, whether it streamed, the tools it
          // offered and whether its body could be read (a side reply means no tools, or a body it could not parse).
          const rows = gatewayStub && gwExec ? (await gwExec(`cat ${shq(gwStubLog)} 2>/dev/null`).catch(() => null))?.stdout ?? "" : "";
          const seen = rows.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean)
            .map((x: any) => `${x.method} ${x.path} stream=${x.stream} tools=${(x.tools ?? []).length}${x.side ? " side" : ""}${x.unread_body !== undefined ? ` unread_body=${x.unread_body} encoding=${x.encoding || "none"}` : ""}`);
          throw new Error(`the reply does not carry the stub's nonce ${nonce} and the tool output: ${last.slice(-200)}${seen.length ? ` (the stub saw: ${seen.slice(-8).join("; ")})` : ""}`);
        }
        return { value: last, detail: last.slice(0, 280) };
      });
      // `--agent claude/MODEL`: the session must run the model asked for. Read from what ran: the `model` of every
      // assistant message in the session's Claude transcript, never the reply's own words (a model gets them wrong
      // about itself) and never `acp session info`, whose record names the model asked for and lists every model
      // the harness offers (so it named the asked model even when a pooled agent ran another one: a second chat
      // on one machine asked claude-sonnet-5-5 and ran claude-haiku-5-5, and this step passed, 2026-11-10).
      if (askedModel && !modelStub && harness === "claude") {
        await J.step("session model", async () => {
          const r = await exec(`${GUEST}"$c" acp --json session info ${shq(session)} 2>&1`, 45_000);
          const asid = /"agentSessionId"\s*:\s*"([^"]+)"/.exec(r.stdout)?.[1];
          if (!asid) throw new Error(`asked ${askedModel}; acp session info names no agentSessionId: ${r.stdout.slice(-200)}`);
          const t = await exec(`${GUEST}${claudeTranscriptModelsProgram(asid)}`, 45_000);
          const ran = transcriptModels(t.stdout);
          if (!ran.length) throw new Error(`asked ${askedModel}; the session's Claude transcript (${asid}) names no model`);
          if (ran.some((m) => m !== askedModel && !m.startsWith(`${askedModel}-`))) throw new Error(`asked ${askedModel}; the agent ran ${ran.join(", ")}`);
          return { value: null, detail: `asked ${askedModel}; the agent ran ${ran.join(", ")} (its Claude transcript)` };
        });
      }
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
      if (gwExec || gatewayLocal) {
        await J.step("gateway: the call went through it", async () => {
          const route = provider === "claude" ? "/v1/messages" : "/v1/responses";
          const r = gwExec
            ? await gwExec(`cat ${shq(gwLog)} 2>/dev/null`)
            : { stdout: localGatewayDir ? readFileSync(path.join(localGatewayDir, "gateway.log"), "utf8") : "" };
          const line = r.stdout.split("\n").find((l) => l.includes(`${created.id} POST ${route}`) && / -> 200 /.test(l));
          if (!line) throw new Error(`no ${route} call from ${created.id} answered 200 in the gateway's log: ${r.stdout.slice(-400)}`);
          if (gatewayStub) {
            const s = await gwExec!(`cat ${shq(gwStubLog)} 2>/dev/null`);
            const rows = s.stdout.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
            if (!rows.some((x: any) => x.method === "POST" && String(x.path).startsWith(route) && x.stream)) throw new Error("the proxy on the gateway machine logged no streamed model request");
          }
          return { value: null, detail: `chat machine -> edge -> cmux -> ${gwExec ? "gateway machine" : "this computer's gateway"} -> proxy: ${line.replace(/^.*?: /, "").slice(0, 160)}` };
        });
        await J.step("the chat machine holds no login", async () => {
          const r = await exec(
            `H=/home/cmux; for f in "$H/.codex/auth.json" "$H/.claude/.credentials.json"; do [ -e "$f" ] && echo "has $f"; done; ` +
              `grep -qs CLAUDE_CODE_OAUTH_TOKEN "$H/.claude/settings.json" && echo "has CLAUDE_CODE_OAUTH_TOKEN"; ` +
              // Credential files only (JSON, TOML, env): Codex's bundled plugin docs under ~/.codex/.tmp mention
              // refresh tokens in prose (gateway-e2e run 42388544286).
              `grep -rlsE --include='*.json' --include='*.toml' --include='*.env' --exclude-dir=.tmp '"refresh_token"|sk-ant-oat' "$H/.codex" "$H/.claude" "$H/.config/cmux" 2>/dev/null | sed 's/^/has /'; echo "@@done"`,
          );
          if (!r.stdout.includes("@@done")) throw new Error(`exit ${r.code} ${r.stderr.slice(-200)}`);
          const found = r.stdout.split("\n").filter((l) => l.startsWith("has "));
          if (found.length) throw new Error(`the chat machine holds a login: ${found.join(", ")}`);
          return { value: null, detail: "no ~/.codex/auth.json, no ~/.claude/.credentials.json, no OAuth or refresh token in the harness folders" };
        });
        if (gwExec && gwStubUrl) {
          const stubUrl: string = gwStubUrl;
          // What the gateway route costs a call (cmuxterm-hq#7415 F1): GET /v1/models, which the stub answers without
          // moving its script, from the chat machine through edge -> Worker -> team object -> gateway socket -> stub,
          // and from the gateway machine straight to the stub. One warm-up call each is not counted.
          await J.step("gateway: hop cost", async () => {
            const n = HOP_SAMPLES;
            // Each call's Server-Timing (cmux-platform InferenceGateway: the Worker's and the team object's spans) follows
            // its timing line as `hop-s <value>`; the stub sends none.
            const loop = (auth: string, url: string) =>
              `h=$(mktemp); for i in $(seq 0 ${n}); do curl -sS -o /dev/null -D "$h" -m 30 ${auth} -w 'hop-t %{http_code} %{time_starttransfer} %{time_total}' ${url}; echo " $?"; ` +
              `tr -d '\\r' < "$h" | awk 'tolower($0) ~ /^server-timing:/ { sub(/^[^:]*:[ \\t]*/, ""); print "hop-s " $0 }'; done; rm -f "$h"`;
            const via = await exec(`. ${VM_MODEL_PLANE_ENV} && ${loop(`-H "Authorization: Bearer $OPENAI_API_KEY"`, `"$OPENAI_BASE_URL/models"`)}`, 300_000);
            const direct = await gwExec!(loop("", shq(`${stubUrl}/v1/models`)), 300_000);
            const a = hopTimes(via.stdout, n);
            const b = hopTimes(direct.stdout, n);
            const result = { samples: n, gateway_path: a, direct: b, added_ms: { ttfb_p50: a.ttfb_p50 - b.ttfb_p50, total_p50: a.total_p50 - b.total_p50 }, by_hop_p50: hopSpans(via.stdout) };
            if (outDir) writeFileSync(path.join(outDir, "gateway-hop.json"), `${JSON.stringify(result, null, 2)}\n`);
            return {
              value: null,
              // The whole result, so the run's summary keeps it (the job uploads no artifact).
              detail: `the route adds ${result.added_ms.ttfb_p50} ms TTFB at p50` +
                (result.by_hop_p50
                  ? `, the team object's own hop ${result.by_hop_p50.object_hop} ms` +
                    (result.by_hop_p50.untimed ? ` (over ${result.by_hop_p50.calls} calls; ${result.by_hop_p50.untimed} came back without Server-Timing)` : "")
                  : " (no Server-Timing came back)") +
                `; ${JSON.stringify(result)}`,
            };
          });
        }
      }
      if (!lifecycle) {
        J.skip("turn 2 (same session)", only.has("lifecycle") ? "--skip lifecycle" : `agent ${agent}`);
        J.skip("daemon restart keeps the session", only.has("lifecycle") ? "--skip lifecycle" : `agent ${agent}`);
      } else {
        await J.step("turn 2 (same session)", async () => laterTurn("Say it once more, in one short sentence."));
        // A link loss as the guest sees it: its agent daemon dies (SIGKILL, no clean shutdown) and acpmux.service
        // (Restart=always) brings it back. The session must still be listed and take a turn, with no new `acp ensure`.
        await J.step("daemon restart keeps the session", async () => {
          const pidOf = async () => {
            const r = await exec(`${GUEST}"$c" acp --json daemon status 2>&1`);
            try { return JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))).pid as number | undefined; } catch { return undefined; }
          };
          const old = await pidOf();
          if (!old) throw new Error("acp daemon status names no pid");
          const k = await exec(`kill -KILL ${old} 2>&1; echo "@@kill $?"`);
          if (!/@@kill 0/.test(k.stdout)) throw new Error(`kill ${old}: ${k.stdout.slice(-200)}`);
          const t0 = Date.now();
          let now: number | undefined;
          while (Date.now() - t0 < 60_000) {
            await sleep(2_000);
            now = await pidOf();
            if (now && now !== old) break;
          }
          if (!now || now === old) throw new Error(`no new daemon within 60 s of killing pid ${old}`);
          const back = Math.round((Date.now() - t0) / 100) / 10;
          const ls = await exec(`${GUEST}"$c" acp ls --json 2>&1`);
          if (!ls.stdout.includes(session)) throw new Error(`the new daemon (pid ${now}) does not list ${session}: ${ls.stdout.slice(-200)}`);
          const turn = await laterTurn("Are you still there? Answer in one short sentence.");
          return { value: null, detail: `daemon ${old} killed, ${now} serves after ${back} s; ${turn.detail}` };
        });
      }
    }

    // After the chat, while its processes still run: where a provider key sits on the chat machine.
    if (only.has("keys")) {
      J.skip(KEY_PROBE_STEP, "--skip keys");
    } else {
      const t0 = Date.now();
      const mode = gatewayAny ? "gateway" : only.has("login") || !login || !provider ? "no login passed" : "login copy";
      try {
        // The walk gets 240 s of the exec route's 300 s; a walk cut short reads as incomplete, never clean.
        const r = await exec(keyProbeCommand(readFileSync(KEY_PROBE_PY, "utf8"), ["--budget-s", "240"]), 290_000);
        const probe = parseKeyProbe(r.stdout);
        if (keysProbeOut) appendFileSync(keysProbeOut, `${JSON.stringify({ tag, backend: backend.name, mode, machine: created.id, at: new Date().toISOString(), ...probe })}\n`);
        const detail = keyProbeDetail(probe);
        const status = keyProbeStatus(probe, keysClean);
        J.record({ step: KEY_PROBE_STEP, status, ms: Date.now() - t0, detail: status === "skip" ? `report only (${mode}; --keys-clean fails it): ${detail}` : `${mode}: ${detail}` });
      } catch (e) {
        J.record({ step: KEY_PROBE_STEP, status: keysClean ? "fail" : "skip", ms: Date.now() - t0, detail: `the probe did not run: ${(e as Error).message}` });
      }
    }

    // The carrier is the only way into a Cloud machine (cmux-platform#1007 deletes the Native link_token and the relay
    // chat), so the journey connects with the carrier dial and nothing else.
    await J.step("connect (connect_info)", async () => {
      const info = await installApi.read("cloud.machine.connect_info", { machine: created.id });
      return { value: null, detail: `host ${info.host} state ${info.state} epoch ${info.epoch}` };
    });
    if (cmux) {
      await J.step("connect (carrier dial)", async () => {
        const d = await carrierDial(cmux, api, created.id);
        return { value: null, detail: dialDetail(d) };
      });
    } else {
      // Without a cmux binary (the production journeys) the dial cannot run; its platform half still can: the
      // ticket, grant and daemon key it asks for, checked by the dial's own rules.
      await J.step("connect (carrier ticket)", async () => {
        const r = await api.raw("POST", `/v1/cloud/machines/${created.id}/carrier`, { noise_key: randomBytes(32).toString("base64url") });
        const problem = carrierTicketProblem(r.status, r.body);
        if (problem) throw new Error(`carrier ticket: ${problem}`);
        return { value: null, detail: `${r.body.value.relay}, ticket until ${r.body.value.expires_at}, grant and daemon key present` };
      });
      J.skip("connect (carrier dial)", "--cmux is required for a carrier dial");
    }
    if (createAnsweredAt !== null) {
      await J.step("guest carrier timeline", async () => {
        const before = Date.now();
        const r = await exec(GUEST_CARRIER_TIMELINE);
        const after = Date.now();
        if (r.code !== 0) throw new Error(`exit ${r.code} ${r.stderr.slice(-200)}`);
        return { value: null, detail: guestTimeline(r.stdout, createAnsweredAt!, before, after, createSentAt ?? createAnsweredAt!) };
      });
    }

    // --chaos: faults injected into this machine's carrier mid-turn, each a step (cloud-chaos.ts).
    if (chaos) {
      if (!cmux || !lifecycle) J.skip("chaos", !cmux ? "--cmux is required for the chaos leg" : "the chaos leg needs a chat session");
      else {
        const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
        const results = await runChaos({
          cmux, machine: created.id, team: api.team, exec, guest: GUEST, session, tag, harness: agent,
          env: { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer },
          log: (line) => console.log(scrub(line, J.secrets)),
        }).catch((e: Error) => [{ fault: "chaos leg", outcome: "fail" as const, felt_ms: null, recover_ms: null, carrier: "", turn: "", detail: e.message }]);
        for (const r of results) {
          J.record({ step: `chaos: ${r.fault}`, status: r.outcome === "ok" ? "pass" : r.outcome === "fail" ? "fail" : "skip", ms: r.felt_ms ?? 0, detail: r.detail });
        }
        if (outDir) writeFileSync(path.join(outDir, "chaos.json"), `${JSON.stringify({ backend: backend.name, machine: created.id, results }, null, 2)}\n`);
        const chaosOut = argValue("--chaos-probe-out", argv);
        if (chaosOut) writeFileSync(chaosOut, `${JSON.stringify(chaosProbeRow(argValue("--chaos-probe", argv) ?? `cloud-carrier-chaos-${backend.name}`, results, process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : undefined))}\n`);
      }
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
      if (cmux) {
        await J.step("carrier dial after resume", async () => {
          const d = await carrierDial(cmux, api, created.id);
          return { value: null, detail: dialDetail(d) };
        });
      } else {
        J.skip("carrier dial after resume", "--cmux is required for a carrier dial");
      }
      if (lifecycle) await J.step("turn after resume", async () => laterTurn("Back after a pause: answer in one short sentence."));
      else J.skip("turn after resume", only.has("lifecycle") ? "--skip lifecycle" : `agent ${agent}`);
    }
    if (!keep) {
      await J.step("delete", async () => {
        await api.deleteMachine(created.id, `${tag}-delete`);
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
