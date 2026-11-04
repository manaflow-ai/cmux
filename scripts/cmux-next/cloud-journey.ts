#!/usr/bin/env bun
/**
 * The NEXT Cloud journey: one command checks a backend end to end, with no app build.
 *
 *   bun scripts/cmux-next/cloud-journey.ts --backend staging
 *   bun scripts/cmux-next/cloud-journey.ts --backend preview-35100 --out /tmp/journey
 *   bun scripts/cmux-next/cloud-journey.ts --backend prod --credentials ~/.secrets/cmuxterm-prod.env --team team_...
 *   bun scripts/cmux-next/cloud-journey.ts --backend local            # wrangler dev on 127.0.0.1:8787
 *   bun scripts/cmux-next/cloud-journey.ts --api https://cmux-api-preview-35100.debussy.workers.dev --stack dev
 *
 * It signs in as the agent test account (Stack password sign-in; CMUX_DOGFOOD_STACK_EMAIL and
 * CMUX_DOGFOOD_STACK_PASSWORD from the environment or a KEY=value --credentials file) and walks the
 * same routes the app and the cmux CLI use, against the cmux API Worker (which forwards Cloud ops to
 * cmux-platform):
 *
 *   health -> sign in -> user.ensure -> install token -> create machine -> running (status) -> listed
 *   -> first exec -> start agent (acpmux on the machine) -> send chat -> reply -> connect (connect_info
 *   + link_token) -> handoff record -> sync push/pull (a folder round trip) -> pause -> resume -> delete
 *
 * Each step prints PASS/FAIL/SKIP with its latency; --out DIR also gets journey.json (the steps) and
 * summary.md (a table for a PR comment or job summary). The machine this run made is deleted at the
 * end, pass or fail, by its exact id, unless --keep. Exit 0 only when no step failed.
 *
 * Exec goes the CLI's own way (`cmux machine access exec`: a client session minted at
 * POST /v1/cloud/machines/{id}/client-session, then the provider's exec-await). --cmux PATH runs every
 * exec through that cmux binary instead, so a CLI change is checked by the same journey.
 *
 * Secrets are read from the environment or files, sent only in headers, and never printed.
 */
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
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

export function summaryMarkdown(backend: Backend, steps: Step[], meta: Record<string, string> = {}): string {
  const failed = steps.filter((s) => s.status === "fail").length;
  const total = steps.reduce((n, s) => n + s.ms, 0);
  const head = `${failed ? "FAIL" : "PASS"}: Cloud journey on \`${backend.name}\` (${backend.api}), ${(total / 1000).toFixed(1)} s`;
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
async function waitMachine(api: Api, machine: string, want: (m: any) => boolean, budgetMs: number): Promise<any> {
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
  return async (command, timeoutMs = 60_000) => {
    if (!session || session.expires_at - Date.now() < 60_000) {
      const r = await api.raw("POST", `/v1/cloud/machines/${machine}/client-session`, { ttl_seconds: 900 });
      if (r.status !== 200 || r.body.ok !== true) throw new Error(`client-session: HTTP ${r.status} ${short(r.body.error?.code ?? r.body.error ?? r.body)}`);
      session = r.body.value;
      journey.secrets.push(session!.token);
    }
    const s = session!;
    const r = await http("POST", `${s.api_base_url.replace(/\/+$/, "")}/v5/vms/${s.vm_id}/exec-await`, { command, linuxUser: s.linux_user, timeoutMs }, { "x-freestyle-identity-access-token": s.token }, timeoutMs + 15_000);
    if (r.status < 200 || r.status >= 300) throw new Error(`exec-await: HTTP ${r.status}`);
    return { code: Number(r.body.statusCode ?? r.body.exitCode ?? r.body.code ?? 0), stdout: String(r.body.stdout ?? ""), stderr: String(r.body.stderr ?? "") };
  };
}

/** `cmux machine access exec` with the same credential: the journey drives the real CLI. */
function cliExec(cmux: string, api: Api, machine: string): Exec {
  return async (command, timeoutMs = 60_000) => {
    const env = { ...process.env, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer };
    const args = ["machine", "access", "exec", "--target", `machine:${machine}`, "--timeout-ms", String(Math.min(timeoutMs, 300_000)), ...(api.team ? ["--team", api.team] : []), "--", "sh", "-c", command];
    const done = spawnSync(cmux, args, { env, encoding: "utf8", timeout: timeoutMs + 30_000 });
    if (done.error) throw new Error(`${cmux}: ${done.error.message}`);
    return { code: done.status ?? 1, stdout: done.stdout ?? "", stderr: done.stderr ?? "" };
  };
}

/** The guest's own cmux-tui (cloud_start_chat.rs GUEST_PRELUDE): the build the machine's acpmux runs. */
const GUEST = 'export HOME="${HOME:-/home/cmux}"; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ';
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

function argValue(flag: string, argv: string[]): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("*/")[0]);
    return 0;
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
  const agent = argValue("--agent", argv) ?? "claude";
  const prompt = argValue("--prompt", argv) ?? "Reply with one short sentence that names the planet you are on.";
  const chatBudget = Number(argValue("--chat-timeout", argv) ?? 300) * 1000;
  const cmux = argValue("--cmux", argv);
  const keep = argv.includes("--keep");
  const only = new Set((argValue("--skip", argv) ?? "").split(",").filter(Boolean));
  const tag = `jr-${Date.now().toString(36)}`;
  const J = new Journey(backend, outDir, { tag, team: team ?? "(personal)", agent, exec: cmux ? `cmux CLI ${cmux}` : "client session" });
  if (password) J.secrets.push(password);
  const api = new Api(backend.api, team);
  let machine: string | null = null;
  let deleted = false;
  try {
    await J.step("health", async () => {
      const r = await http("GET", `${backend.api}/v1/health`, undefined, {});
      if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body)}`);
      return { value: null, detail: `commit ${r.body.commit ?? r.body.version ?? "?"}` };
    });
    if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
    const stack = STACK[backend.stack];
    api.bearer = await J.step("sign in (agent test account)", async () => {
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

    const created = await J.step("create machine", async () => {
      const v = await api.op("cloud.machine.create", { name: `cloud journey ${tag}`, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${tag}-create`);
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

    const exec = cmux ? cliExec(cmux, api, created.id) : directExec(api, created.id, J);
    await J.step("first exec", async () => {
      const r = await exec("echo journey-ok; uname -m");
      if (r.code !== 0 || !r.stdout.includes("journey-ok")) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
      return { value: null, detail: r.stdout.trim().split("\n").join(" ") };
    });

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
          if (wait === "0" && last) return { value: last, detail: last.slice(0, 280) };
          if (wait === "2") throw new Error(`the agent waits on a permission: ${last.slice(-200)}`);
          if (wait && wait !== "3" && wait !== "0") throw new Error(`acp wait exit ${wait}: ${last.slice(-300)}`);
        }
        throw new Error(`no reply within ${chatBudget / 1000} s; last: ${last.slice(-300)}`);
      });
    }

    await J.step("connect (connect_info + link_token)", async () => {
      const info = await installApi.read("cloud.machine.connect_info", { machine: created.id });
      const tok = await installApi.op("cloud.machine.link_token", { host: bound.host, services: ["daemon"] });
      if (!tok?.expires_at) throw new Error(`link_token answered ${short(Object.keys(tok ?? {}))}`);
      return { value: null, detail: `host ${info.host} state ${info.state} epoch ${info.epoch}; link token until ${tok.expires_at}` };
    });
    J.skip("connect (link dial)", "a headless link dial needs a credential source without the Mac app's relay (cmux link dial fails closed today)");

    await J.step("handoff record", async () => {
      const r = await api.raw("POST", "/v1/handoffs", { machine: created.id, title: `cloud journey ${tag}`, harness: agent });
      if (r.status === 404) throw new Error(`/v1/handoffs: 404 on this backend`);
      if (r.status >= 300) throw new Error(`/v1/handoffs: HTTP ${r.status} ${short(r.body.error ?? r.body)}`);
      return { value: null, detail: `HTTP ${r.status} ${short(r.body.value?.id ?? r.body.id ?? r.body)}` };
    }).catch(() => undefined);

    await J.step("sync push/pull (folder round trip)", async () => {
      const dir = `/tmp/journey-sync-${tag}`;
      const payload = Buffer.from(`journey ${tag} ${Date.now()}\n`.repeat(64)).toString("base64");
      const push = await exec(`mkdir -p ${dir}/a && printf '%s' ${shq(payload)} | base64 -d > ${dir}/a/file.txt && sha256sum ${dir}/a/file.txt | cut -c1-64`);
      const pull = await exec(`cat ${dir}/a/file.txt | base64 -w0; echo; rm -rf ${dir}`);
      const back = Buffer.from(pull.stdout.trim(), "base64").toString();
      if (push.code !== 0 || back !== Buffer.from(payload, "base64").toString()) throw new Error(`round trip differs (push exit ${push.code}, pull exit ${pull.code})`);
      return { value: null, detail: `${back.length} bytes up and back over exec (link sync needs the headless link dial)` };
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
        const m = await waitMachine(api, created.id, (x) => !x || x.status === "deleted" || x.status === "deleting", 120_000).catch(() => null);
        return { value: null, detail: `${created.id} ${m?.status ?? "gone"}` };
      });
    }
  } catch {
    // The failed step is recorded; cleanup below.
  } finally {
    if (machine && !deleted && !keep) {
      const id: string = machine;
      await J.step("delete (cleanup)", async () => {
        await api.op("cloud.machine.delete", { machine: id }, `${tag}-delete`);
        return { value: null, detail: id };
      }).catch(() => undefined);
    }
  }
  const failed = J.steps.filter((s) => s.status === "fail");
  console.log(`\n${failed.length ? "FAIL" : "PASS"} ${backend.name}: ${J.steps.filter((s) => s.status === "pass").length} passed, ${failed.length} failed, ${J.steps.filter((s) => s.status === "skip").length} skipped, ${(J.steps.reduce((n, s) => n + s.ms, 0) / 1000).toFixed(1)} s`);
  return failed.length ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
