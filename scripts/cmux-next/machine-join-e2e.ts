#!/usr/bin/env bun
/**
 * Machine join end to end on the DEVELOPMENT platform, for .github/workflows/machine-join-e2e.yml.
 *
 *   bun scripts/cmux-next/machine-join-e2e.ts --origin https://cmux-platform-development.debussy.workers.dev \
 *     --acpmux PATH --user USER --home DIR --name NAME --evidence FILE --run ID --sha SHA
 *
 * The stack account comes only from this process's environment (CMUX_UITEST_STACK_EMAIL and
 * CMUX_UITEST_STACK_PASSWORD, which the workflow maps from the repo's dev stack secrets). This
 * process signs in, gets a cmux-api-development access token, mints a join token (cmj_) and
 * writes it to `acpmux host join`'s stdin, all in memory. Every token is masked (::add-mask::) the
 * moment it exists. Children get a fixed environment (no secret), argv carries no secret, and
 * nothing secret is written to disk, the log or the evidence. acpmux runs as the disposable OS
 * user (`sudo -n -u USER env -i`), whose home the job deletes afterwards.
 *
 * Steps: mint, join (stdin), daemon in the foreground until a heartbeat under 90 s, status, the
 * platform list entry matched by joinTokenId, consent (both none), credential file mode 600,
 * revoke, status and list show revoked, secret scan, evidence. The machine revoke and the install
 * revoke run in `finally` and on SIGINT/SIGTERM, so every path after the mint revokes.
 * Exit 0 when the evidence says pass, 1 otherwise, 2 for a refused invocation.
 */
import { spawn } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

export const DEV_PLATFORM = "https://cmux-platform-development.debussy.workers.dev"
export const DEV_API = "https://cmux-api-development.debussy.workers.dev"
const STACK_API = "https://api.stack-auth.com/api/v1"
// The development Stack project cmux-api-development trusts (backend/apps/api/wrangler.jsonc), and its public client key.
const DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
const DEV_STACK_CLIENT_KEY = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
const USER_AGENT = "cmux-machine-join-e2e/1"
export const HEARTBEAT_LIMIT_S = 90
export const CHILD_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/
const USER = /^[a-z_][a-z0-9_-]{0,31}$/

export interface Options {
  origin: string
  acpmux: string
  user: string
  home: string
  name: string
  evidence: string
  runId: string
  sha: string
}

export interface ChildResult {
  code: number | null
  stdout: string
  stderr: string
}

export interface Daemon {
  /** Stops the process (SIGTERM, then SIGKILL) and answers what it printed. */
  stop(): Promise<ChildResult>
}

export interface Deps {
  fetch: (url: string, init: RequestInit) => Promise<Response>
  /** Runs argv with exactly `env`, writing `stdin` (then closing it) when given. */
  run(argv: string[], options: { env: Record<string, string>; stdin?: string; timeoutMs: number }): Promise<ChildResult>
  /** Starts a long-running argv with exactly `env`; stdin is closed. */
  start(argv: string[], options: { env: Record<string, string> }): Daemon
  /** One line of this step's output (the job log). */
  write(line: string): void
  writeFile(path: string, text: string): void
  now(): number
  sleep(ms: number): Promise<void>
}

export interface Evidence {
  run: { id: string; sha: string }
  hubOrigin: string
  name: string
  machineId: string | null
  teamId: string | null
  joinTokenId: string | null
  status: {
    credentialPresent: boolean | null
    joinIncomplete: boolean | null
    revoked: boolean | null
    hubReachable: boolean | null
    heartbeatAgeSeconds: number | null
  }
  consent: { screen: string | null; control: string | null }
  credentialFileMode: string | null
  list: { machineId: string; label: string | null; revoked: boolean; lastHeartbeatPresent: boolean } | null
  secretScan: {
    home: { cmj: number | null; cmm: number | null; credentialFileCmm: number | null }
    log: { cmj: number; cmm: number }
    evidence: { cmj: number; cmm: number }
  }
  revoke: { revokedListed: boolean | null; statusRevoked: boolean | null }
  result: "pass" | "fail"
  reason: string
}

class Refused extends Error {}
class Failed extends Error {}

/** The refusal for an invocation, or undefined: the origin is development only, the names are plain. */
export function refusal(opts: Options): string | undefined {
  if (opts.origin !== DEV_PLATFORM) return `origin must be ${DEV_PLATFORM}`
  if (!NAME.test(opts.name)) return "name must be 1-63 letters, digits, dot, underscore or dash"
  if (!USER.test(opts.user) || opts.user === "root") return "user must be a plain disposable login name"
  if (!opts.home.startsWith("/") || opts.home.includes("..")) return "home must be an absolute path"
  if (!opts.acpmux.startsWith("/")) return "acpmux must be an absolute path"
  if (!opts.evidence.startsWith("/")) return "evidence must be an absolute path"
  return undefined
}

const count = (text: string, needle: string) => text.split(needle).length - 1
/** A workflow command's data, escaped as the runner reads it back. */
export const escapeData = (value: string) => value.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A")
const JWT = /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\./g
const TOKENISH = /cm[jm]_[A-Za-z0-9_-]+/g

/** What in `text` must never be in evidence: either prefix, a JWT, a bearer header, or any held secret. */
export function evidenceLeaks(text: string, secrets: ReadonlyArray<string>): string[] {
  const found: string[] = []
  if (text.includes("cmj_")) found.push("join token prefix")
  if (text.includes("cmm_")) found.push("credential prefix")
  if (new RegExp(JWT.source).test(text)) found.push("jwt")
  if (/bearer|authorization/i.test(text)) found.push("auth header")
  if (secrets.some((s) => s.length >= 4 && text.includes(s))) found.push("held secret")
  return found
}

/** `text` with every held secret, token, credential and JWT replaced. */
export function redact(text: string, secrets: ReadonlyArray<string>): string {
  let out = text
  for (const s of secrets) if (s.length >= 4) out = out.split(s).join("[secret]")
  return out.replace(TOKENISH, (m) => `${m.slice(0, 4)}[redacted]`).replace(JWT, "[jwt].")
}

const b64u = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("base64url")

/**
 * The whole run. `onCleanup` receives `cancel` as soon as it exists: a signal handler calls it to stop
 * the main flow and run the one cleanup pass (stop the user's processes, revoke the machine, revoke the
 * install, sign out) at once.
 */
export async function runE2E(
  opts: Options,
  env: Record<string, string | undefined>,
  deps: Deps,
  onCleanup?: (cancel: () => Promise<void>) => void
): Promise<Evidence> {
  const secrets: string[] = []
  const transcript: string[] = []
  const childText: string[] = []
  const say = (line: string) => {
    transcript.push(line)
    deps.write(line)
  }
  const hold = (value: string) => {
    if (!value) return
    // The runner swallows this command and hides the value everywhere after it. The value is escaped as
    // a workflow command's data (% CR LF), and each line of a multi-line value is masked on its own too.
    deps.write(`::add-mask::${escapeData(value)}`)
    for (const line of value.split(/\r?\n|\r/)) if (line && line !== value) deps.write(`::add-mask::${escapeData(line)}`)
    secrets.push(value)
  }
  const evidence: Evidence = {
    run: { id: opts.runId, sha: opts.sha },
    hubOrigin: opts.origin,
    name: opts.name,
    machineId: null,
    teamId: null,
    joinTokenId: null,
    status: { credentialPresent: null, joinIncomplete: null, revoked: null, hubReachable: null, heartbeatAgeSeconds: null },
    consent: { screen: null, control: null },
    credentialFileMode: null,
    list: null,
    secretScan: { home: { cmj: null, cmm: null, credentialFileCmm: null }, log: { cmj: 0, cmm: 0 }, evidence: { cmj: 0, cmm: 0 } },
    revoke: { revokedListed: null, statusRevoked: null },
    result: "fail",
    reason: ""
  }
  const problems: string[] = []
  const expect = (ok: boolean, what: string) => {
    if (!ok) problems.push(what)
    return ok
  }

  const childEnv = { PATH: CHILD_PATH }
  const asUser = (args: string[]) => [
    "sudo", "-n", "-u", opts.user, "--", "/usr/bin/env", "-i", "-C", opts.home,
    `HOME=${opts.home}`, `USER=${opts.user}`, `LOGNAME=${opts.user}`, `PATH=${CHILD_PATH}`, "LANG=C.UTF-8",
    opts.acpmux, ...args
  ]
  const asRoot = (args: string[]) => ["sudo", "-n", "--", ...args]
  const acpmux = async (args: string[], stdin?: string) => {
    // No new process of the disposable user once cleanup has begun (it has stopped them all).
    live()
    const r = await deps.run(asUser(args), { env: childEnv, timeoutMs: 60_000, ...(stdin === undefined ? {} : { stdin }) })
    childText.push(r.stdout, r.stderr)
    return r
  }
  // acpmux prints one pretty-printed JSON object on stdout (cli/output.rs print_json).
  const lastJson = (text: string): any => {
    const start = text.indexOf("{")
    if (start < 0) return undefined
    try {
      return JSON.parse(text.slice(start))
    } catch {
      return undefined
    }
  }
  // A cancel aborts every request in flight and shortens the ones cleanup makes to 3 s, so the revoke
  // fits inside the runner's grace (SIGINT, then SIGTERM 7.5 s later, then SIGKILL).
  let cancelled = false
  let inFlight = new AbortController()
  const call = async (url: string, init: { method: string; headers?: Record<string, string>; body?: unknown }) => {
    const res = await deps.fetch(url, {
      method: init.method,
      redirect: "error",
      signal: AbortSignal.any([AbortSignal.timeout(cancelled ? 3_000 : 20_000), inFlight.signal]),
      headers: { "user-agent": USER_AGENT, ...(init.body === undefined ? {} : { "content-type": "application/json" }), ...init.headers },
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) })
    })
    const json = (await res.json().catch(() => ({}))) as any
    return { status: res.status, json }
  }
  // An error names the step, the status and the server's code only (a plain identifier), never a body
  // or message that could echo a value.
  const refusedBy = (step: string, r: { status: number; json: any }) => {
    const code = [r.json?.code, r.json?.error?.code].find((c) => typeof c === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(c) && !/cm[jm]_/.test(c))
    return new Failed(`${step}: HTTP ${r.status}${code ? ` ${code}` : ""}`)
  }

  // Session state, all in memory.
  let stack: { access: string; refresh: string } | undefined
  let user: string | undefined
  let install: string | undefined
  let keys: CryptoKeyPair | undefined
  let access: { token: string; expiresAt: number } | undefined
  let token: string | undefined
  let daemon: Daemon | undefined
  let credentialPath: string | undefined
  let machineRevoked = false
  // The join child while it runs; cleanup waits for it, since it may redeem the token at any moment.
  let joining: Promise<ChildResult> | undefined
  let joinStarted = false

  const op = async (name: string, params: unknown) => {
    const r = await call(`${DEV_API}/v1/ops`, {
      method: "POST",
      headers: { authorization: `Bearer ${stack!.access}` },
      body: { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" }
    })
    if (r.status !== 200 || r.json?.ok !== true) throw refusedBy(name, r)
    return r.json.value
  }
  const accessToken = async () => {
    if (access && access.expiresAt - deps.now() > 60_000) return access.token
    const ch = await call(`${DEV_API}/v1/auth/challenge`, { method: "POST", body: { user, install } })
    if (ch.status !== 200 || typeof ch.json?.nonce !== "string") throw refusedBy("auth challenge", ch)
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys!.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const tok = await call(`${DEV_API}/v1/auth/token`, { method: "POST", body: { user, install, nonce: ch.json.nonce, signature: b64u(signature) } })
    if (typeof tok.json?.access_token === "string") hold(tok.json.access_token)
    if (tok.status !== 200 || typeof tok.json?.access_token !== "string") throw refusedBy("auth token", tok)
    access = { token: tok.json.access_token, expiresAt: Number(tok.json.expires_at) || deps.now() + 300_000 }
    return access.token
  }
  const platform = async (method: string, path: string, body?: unknown) =>
    call(`${opts.origin}${path}`, { method, headers: { authorization: `Bearer ${await accessToken()}` }, ...(body === undefined ? {} : { body }) })
  const listEntry = async () => {
    const r = await platform("GET", "/v1/machines/credentials")
    if (r.status !== 200 || !Array.isArray(r.json?.machines)) throw refusedBy("list", r)
    return (r.json.machines as any[]).find((m) => m?.joinTokenId === evidence.joinTokenId)
  }
  // One retry: status records a revoke under the join lock, which the daemon's heartbeat may hold for a moment.
  const status = async () => {
    for (let attempt = 0; ; attempt++) {
      const r = await acpmux(["host", "join", "--status", "--json"])
      const s = lastJson(r.stdout)
      if (r.code === 0 && s) return s
      if (attempt >= 1) throw new Failed(`status: exit ${r.code}`)
      await deps.sleep(1_000)
    }
  }

  // Self-healing for a run that was killed before its revoke (a runner lost, SIGKILL): revoke this
  // account's own CI machines (label ci-join-<digits>, minted by this user) still joined 30 minutes
  // after they were made. Never fails the run.
  const sweepStale = async () => {
    try {
      const r = await platform("GET", "/v1/machines/credentials")
      if (r.status !== 200 || !Array.isArray(r.json?.machines)) return
      let swept = 0
      for (const m of r.json.machines as any[]) {
        const made = Date.parse(String(m?.createdAt ?? ""))
        if (m?.revoked !== false || m?.mintedBy !== user || !/^ci-join-\d+(?:-\d+)?$/.test(String(m?.label ?? ""))) continue
        if (!Number.isFinite(made) || deps.now() - made < 30 * 60_000 || typeof m.machineId !== "string") continue
        const done = await platform("POST", `/v1/machines/credentials/${encodeURIComponent(m.machineId)}/revoke`)
        if (done.status >= 200 && done.status < 300) swept += 1
      }
      if (swept > 0) say(`revoked ${swept} machine(s) an earlier interrupted run left joined`)
    } catch {
      say("::warning::could not sweep earlier runs' machines")
    }
  }

  const revokeMachine = async () => {
    if (machineRevoked || !evidence.joinTokenId || !joinStarted) return
    // A join that failed or was interrupted after the redeem still left a machine: find it by its join
    // token, a few times, since the list may not show it at once (6 reads over about 10 s; 3 over 2 s
    // when cancelled). The join process is already gone here, so no redeem can start later.
    let machineId = evidence.machineId ?? undefined
    for (let attempt = 0; !machineId && attempt < (cancelled ? 3 : 6); attempt++) {
      if (attempt > 0) await deps.sleep(cancelled ? 1_000 : 2_000)
      const found = (await listEntry())?.machineId
      if (typeof found === "string" && found) machineId = found
    }
    if (!machineId) return
    evidence.machineId = machineId
    const r = await platform("POST", `/v1/machines/credentials/${encodeURIComponent(machineId)}/revoke`)
    if (r.status < 200 || r.status >= 300) throw refusedBy("revoke", r)
    machineRevoked = true
    say(`revoked machine ${machineId}`)
  }

  // Every process the disposable user runs (the join, status, the daemon and its children), and nothing
  // else: `kill -1` run as that user signals exactly that user's processes.
  const killUser = (signal: "TERM" | "KILL") =>
    deps.run(["sudo", "-n", "-u", opts.user, "--", "/bin/kill", `-${signal}`, "-1"], { env: childEnv, timeoutMs: 5_000 })

  // One pass, in this order: no new join or daemon can start (the main flow checks `cleaning`); every
  // process of the disposable user is stopped and awaited; the machine is revoked (found by its join
  // token when the join did not report it); then the run's install is revoked and the session signed out.
  let cleaning: Promise<void> | undefined
  const cleanup = () =>
    (cleaning ??= (async () => {
      inFlight.abort()
      inFlight = new AbortController()
      const stopping = daemon?.stop()
      daemon = undefined
      if (joinStarted) {
        await killUser("TERM")
        const bound = cancelled ? 2_000 : 10_000
        await Promise.race([Promise.all([joining?.catch(() => undefined), stopping]), deps.sleep(bound)])
        await killUser("KILL")
      }
      if (stopping) {
        const r = await Promise.race([stopping, deps.sleep(1_000).then(() => undefined)])
        if (r) childText.push(r.stdout, r.stderr)
      }
      try {
        await revokeMachine()
        // A run that failed before its own revoke check still proves the revoke here.
        if (machineRevoked && evidence.revoke.revokedListed === null) evidence.revoke.revokedListed = (await listEntry())?.revoked === true
      } catch (e) {
        problems.push(e instanceof Failed ? e.message : "revoke failed")
      }
      if (evidence.joinTokenId && joinStarted && !machineRevoked && !evidence.machineId) say("no machine was listed for this join token; nothing to revoke")
      if (install && stack) {
        await op("install.revoke", { install }).then(
          () => say("revoked the run's cmux install"),
          () => say("::warning::could not revoke the run's cmux install")
        )
      }
      if (stack) {
        await call(`${STACK_API}/auth/sessions/current`, {
          method: "DELETE",
          headers: { ...stackHeaders(), "x-stack-access-token": stack.access, "x-stack-refresh-token": stack.refresh }
        }).catch(() => undefined)
      }
    })())
  /** A signal or the deadline: stop the main flow and clean up now, on short timeouts. */
  const cancel = () => {
    cancelled = true
    problems.push("cancelled")
    return cleanup()
  }
  // The main flow stops at these points once cleanup has begun.
  const live = () => {
    if (cleaning) throw new Failed("cancelled before the next step")
  }
  onCleanup?.(cancel)
  const stackHeaders = () => ({ "x-stack-project-id": DEV_STACK_PROJECT, "x-stack-publishable-client-key": DEV_STACK_CLIENT_KEY, "x-stack-access-type": "client" })

  try {
    const why = refusal(opts)
    if (why) throw new Refused(why)
    const email = env.CMUX_UITEST_STACK_EMAIL ?? ""
    const password = env.CMUX_UITEST_STACK_PASSWORD ?? ""
    if (!email || !password) throw new Refused("CMUX_UITEST_STACK_EMAIL and CMUX_UITEST_STACK_PASSWORD must be set")
    hold(email)
    hold(password)

    // 1. Stack sign-in (development project), cmux user, a throwaway install and its access token.
    const signIn = await call(`${STACK_API}/auth/password/sign-in`, { method: "POST", headers: stackHeaders(), body: { email, password } })
    for (const key of ["access_token", "refresh_token"]) if (typeof signIn.json?.[key] === "string") hold(signIn.json[key])
    if (signIn.status !== 200 || typeof signIn.json?.access_token !== "string") throw refusedBy("stack sign-in", signIn)
    stack = { access: signIn.json.access_token, refresh: String(signIn.json.refresh_token ?? "") }
    say("signed in to the development stack project")
    user = String((await op("user.ensure", {}))?.id ?? "")
    keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey
    install = String(
      (await op("install.register", {
        public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
        kind: "cli",
        name: `machine-join-e2e ${opts.runId}`.slice(0, 80),
        device_name: "machine-join-e2e runner",
        platform: "linux"
      }))?.id ?? ""
    )
    await accessToken()
    say("cmux-api-development access token ready")
    await sweepStale()

    // 2. Mint.
    live()
    const mint = await platform("POST", "/v1/machines/join-tokens", { label: opts.name, ttlSeconds: 600 })
    if (typeof mint.json?.token === "string") hold(mint.json.token)
    if (mint.status !== 200 || typeof mint.json?.token !== "string" || !/^cmj_[A-Za-z0-9_-]{16,4096}$/.test(mint.json.token)) throw refusedBy("mint", mint)
    token = mint.json.token as string
    const id = (v: unknown) => (typeof v === "string" && /^[A-Za-z0-9._:-]{1,256}$/.test(v) ? v : null)
    evidence.joinTokenId = id(mint.json.joinTokenId)
    evidence.teamId = id(mint.json.teamId)
    // Without its id, a joined machine could not be found to revoke: never join then.
    if (!evidence.joinTokenId || !evidence.teamId) throw new Failed("mint: no joinTokenId or teamId")
    say(`minted join token ${evidence.joinTokenId} for team ${evidence.teamId}`)

    // 3. Join: the token goes to stdin only, then this process drops it.
    live()
    joinStarted = true
    joining = acpmux(["host", "join", "--hub", opts.origin, "--name", opts.name, "--json"], `${token}\n`)
    token = undefined
    const joined = await joining
    joining = undefined
    const j = lastJson(joined.stdout)
    if (joined.code !== 0 || j?.joined !== true) {
      const meaning: Record<number, string> = { 2: "malformed", 3: "expired or used", 4: "hub unreachable", 5: "store failed" }
      throw new Failed(`join: exit ${joined.code}${joined.code !== null && meaning[joined.code] ? ` (${meaning[joined.code]})` : ""}`)
    }
    evidence.machineId = typeof j.machineId === "string" && j.machineId ? j.machineId : null
    if (!evidence.machineId) throw new Failed("join: no machineId")
    expect(j.teamId === evidence.teamId, "join team differs from the mint's team")
    say(`joined as machine ${evidence.machineId}`)

    // The stored credential is masked before anything else could print it.
    const pre = await status()
    credentialPath = String(pre.credentialPath ?? "")
    if (!credentialPath.startsWith(`${opts.home}/`)) throw new Failed("status: credential path is outside the disposable home")
    const file = await deps.run(asRoot(["cat", "--", credentialPath]), { env: childEnv, timeoutMs: 10_000 })
    let record: any
    try {
      record = JSON.parse(file.stdout)
    } catch {
      throw new Failed("credential file is not JSON")
    }
    if (typeof record?.credential === "string") hold(record.credential)
    if (typeof record?.credential !== "string" || !/^cmm_[A-Za-z0-9_-]{16,4096}$/.test(record.credential)) throw new Failed("credential file holds no credential")
    if (record.machine_id !== evidence.machineId) throw new Failed("credential file names another machine")

    // 4. Daemon in the foreground until a heartbeat under the limit.
    live()
    daemon = deps.start(asUser(["daemon", "run"]), { env: childEnv })
    const deadline = deps.now() + HEARTBEAT_LIMIT_S * 1000
    let s: any = pre
    for (;;) {
      s = await status()
      const beat = Number(s.lastHeartbeat)
      if (Number.isFinite(beat) && beat > 0) {
        evidence.status.heartbeatAgeSeconds = Math.max(0, Math.round((deps.now() - beat) / 1000))
        if (evidence.status.heartbeatAgeSeconds < HEARTBEAT_LIMIT_S) break
      }
      if (deps.now() >= deadline) break
      await deps.sleep(3_000)
    }
    evidence.status.credentialPresent = s.credentialPresent === true
    evidence.status.joinIncomplete = s.joinIncomplete === true
    evidence.status.revoked = s.revoked === true
    evidence.status.hubReachable = s.hubReachable === true
    evidence.consent = { screen: String(s.consent?.screen ?? "") || null, control: String(s.consent?.control ?? "") || null }
    expect(evidence.status.credentialPresent, "status: no credential")
    expect(!evidence.status.joinIncomplete, "status: join incomplete")
    expect(!evidence.status.revoked, "status: revoked before the revoke")
    expect(evidence.status.hubReachable, "status: hub unreachable")
    expect(evidence.status.heartbeatAgeSeconds !== null && evidence.status.heartbeatAgeSeconds < HEARTBEAT_LIMIT_S, `no heartbeat within ${HEARTBEAT_LIMIT_S} s`)
    expect(s.machineId === evidence.machineId, "status: machine differs from the join's")
    expect(evidence.consent.screen === "none" && evidence.consent.control === "none", "consent is not none for both screen and control")

    // 5. The platform's list, by join token id.
    const row = await listEntry()
    if (row) evidence.list = { machineId: String(row.machineId), label: row.label ?? null, revoked: row.revoked === true, lastHeartbeatPresent: typeof row.lastHeartbeat === "string" && row.lastHeartbeat !== "" }
    expect(evidence.list?.machineId === evidence.machineId, "list: no entry for this join token")
    expect(evidence.list?.revoked === false, "list: revoked before the revoke")
    expect(evidence.list?.lastHeartbeatPresent === true, "list: no heartbeat")

    // 6. Credential file mode.
    const mode = await deps.run(asRoot(["stat", "-c", "%a", "--", credentialPath]), { env: childEnv, timeoutMs: 10_000 })
    evidence.credentialFileMode = mode.stdout.trim() || null
    expect(evidence.credentialFileMode === "600", "credential file mode is not 600")

    // 7. Revoke, then status and list say revoked.
    await revokeMachine()
    const after = await status()
    evidence.revoke.statusRevoked = after.revoked === true
    evidence.revoke.revokedListed = (await listEntry())?.revoked === true
    expect(evidence.revoke.statusRevoked, "status does not show revoked")
    expect(evidence.revoke.revokedListed, "list does not show revoked")
  } catch (e) {
    if (e instanceof Refused) throw e
    problems.unshift(e instanceof Failed ? e.message : `unexpected error (${e instanceof Error ? e.name : "unknown"})`)
  } finally {
    await cleanup()
  }

  // 8. Secret scan: the disposable home (the credential file holds exactly its one credential),
  // everything this step printed and every acpmux process's output.
  try {
    // Incomplete is a failure: the listing and every read must succeed.
    const listing = await deps.run(asRoot(["find", opts.home, "-xdev", "-type", "f", "-print0"]), { env: childEnv, timeoutMs: 30_000 })
    if (listing.code !== 0) throw new Error("find failed")
    let cmj = 0
    let cmm = 0
    for (const path of listing.stdout.split("\0").filter(Boolean)) {
      const read = await deps.run(asRoot(["cat", "--", path]), { env: childEnv, timeoutMs: 10_000 })
      if (read.code !== 0) throw new Error("read failed")
      const text = read.stdout
      cmj += count(text, "cmj_")
      if (path === credentialPath) evidence.secretScan.home.credentialFileCmm = count(text, "cmm_")
      else cmm += count(text, "cmm_")
    }
    evidence.secretScan.home.cmj = cmj
    evidence.secretScan.home.cmm = cmm
  } catch {
    evidence.secretScan.home.cmj = null
    evidence.secretScan.home.cmm = null
    problems.push("could not scan the whole disposable home")
  }
  const logText = [...transcript, ...childText].join("\n")
  evidence.secretScan.log = { cmj: count(logText, "cmj_"), cmm: count(logText, "cmm_") }
  expect(evidence.secretScan.home.cmj === 0, "the home holds a join token")
  if (credentialPath) expect(evidence.secretScan.home.credentialFileCmm === 1, "the credential file does not hold exactly one credential")
  expect(evidence.secretScan.home.cmm === 0, "the home holds a credential outside the credential file")
  expect(evidence.secretScan.log.cmj === 0 && evidence.secretScan.log.cmm === 0, "output holds a token or credential")
  if (secrets.some((s) => s.length >= 4 && logText.includes(s))) problems.push("output holds a secret value")

  evidence.result = problems.length === 0 ? "pass" : "fail"
  evidence.reason = problems.length === 0 ? "joined, heartbeat, listed, consent none, mode 600, revoked, no secrets found" : problems.join("; ")
  // 9. The evidence itself: scanned before it goes anywhere; a leak replaces it with a bare failure.
  let text = JSON.stringify(evidence, null, 2)
  const leaks = evidenceLeaks(text, secrets)
  evidence.secretScan.evidence = { cmj: count(text, "cmj_"), cmm: count(text, "cmm_") }
  if (leaks.length > 0) {
    const bare: Evidence = { ...evidence, list: null, reason: "evidence redaction check failed", result: "fail", machineId: null, teamId: null, joinTokenId: null, name: "" }
    text = JSON.stringify(bare, null, 2)
    if (evidenceLeaks(text, secrets).length > 0) text = JSON.stringify({ run: evidence.run, result: "fail", reason: "evidence redaction check failed" })
    deps.writeFile(opts.evidence, `${text}\n`)
    say(`machine join e2e: fail (evidence redaction check failed)`)
    return JSON.parse(text)
  }
  text = JSON.stringify(evidence, null, 2)
  deps.writeFile(opts.evidence, `${text}\n`)
  say(`machine join e2e: ${evidence.result}${evidence.result === "fail" ? ` (${redact(evidence.reason, secrets)})` : ""}`)
  if (evidence.result === "fail") {
    // The tail of what acpmux printed, redacted, to debug a failure.
    for (const line of childText.join("\n").split("\n").filter((l) => l.trim()).slice(-40)) say(`  acpmux: ${redact(line, secrets).slice(0, 300)}`)
  }
  return evidence
}

export function parseArgs(argv: string[]): Options {
  const value = (flag: string) => {
    const i = argv.indexOf(flag)
    return i >= 0 && i + 1 < argv.length ? argv[i + 1]! : ""
  }
  return {
    origin: value("--origin"),
    acpmux: value("--acpmux"),
    user: value("--user"),
    home: value("--home"),
    name: value("--name"),
    evidence: value("--evidence"),
    runId: value("--run"),
    sha: value("--sha")
  }
}

/** Production dependencies: sudo children with exactly the given environment, output kept in memory. */
export function realDeps(): Deps {
  const collect = (argv: string[], env: Record<string, string>, stdin: string | undefined) => {
    const child = spawn(argv[0]!, argv.slice(1), { env, cwd: "/", stdio: ["pipe", "pipe", "pipe"] })
    const out: Buffer[] = []
    const err: Buffer[] = []
    child.stdout.on("data", (b: Buffer) => out.push(b))
    child.stderr.on("data", (b: Buffer) => err.push(b))
    child.stdin.on("error", () => undefined)
    if (stdin !== undefined) child.stdin.write(stdin)
    child.stdin.end()
    const done = new Promise<ChildResult>((resolve) => {
      child.on("error", () => resolve({ code: null, stdout: "", stderr: "spawn failed" }))
      child.on("close", (code) => resolve({ code, stdout: Buffer.concat(out).toString("latin1"), stderr: Buffer.concat(err).toString("latin1") }))
    })
    return { child, done }
  }
  return {
    fetch: (url, init) => fetch(url, init),
    run: async (argv, { env, stdin, timeoutMs }) => {
      const { child, done } = collect(argv, env, stdin)
      const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs)
      try {
        return await done
      } finally {
        clearTimeout(timer)
      }
    },
    start: (argv, { env }) => {
      const { child, done } = collect(argv, env, undefined)
      return {
        stop: async () => {
          // sudo relays SIGTERM to acpmux; the job's cleanup step kills the user's leftovers.
          child.kill("SIGTERM")
          const kill = setTimeout(() => child.kill("SIGKILL"), 10_000)
          try {
            return await done
          } finally {
            clearTimeout(kill)
          }
        }
      }
    },
    write: (line) => process.stdout.write(`${line}\n`),
    writeFile: (path, text) => {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
      writeFileSync(path, text, { mode: 0o600 })
    },
    now: () => Date.now(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms))
  }
}

if (import.meta.main) {
  const env = { CMUX_UITEST_STACK_EMAIL: process.env.CMUX_UITEST_STACK_EMAIL, CMUX_UITEST_STACK_PASSWORD: process.env.CMUX_UITEST_STACK_PASSWORD }
  // Gone from this process's environment before anything starts; children get a fixed env anyway.
  delete process.env.CMUX_UITEST_STACK_EMAIL
  delete process.env.CMUX_UITEST_STACK_PASSWORD
  const opts = parseArgs(process.argv.slice(2))
  const why = refusal(opts)
  if (why) {
    console.error(`machine-join-e2e: refused: ${why}`)
    process.exit(2)
  }
  // A cancel or a step timeout (SIGINT, then SIGTERM about 7.5 s later) stops the run and revokes at
  // once; the run then writes its (failed) evidence and exits. 9 s after the first signal it exits anyway.
  // The run's own deadline (12 minutes, under the step's 15) cancels the same way.
  let cancelNow: (() => Promise<void>) | undefined
  // Handled, not default, for both signals and every repeat: the second one must not kill the cleanup.
  let stopping = false
  const stop = () => {
    if (stopping) return
    stopping = true
    cancelNow?.()
    setTimeout(() => process.exit(130), 9_000).unref()
  }
  for (const sig of ["SIGINT", "SIGTERM"] as const) process.on(sig, stop)
  setTimeout(() => cancelNow?.(), 12 * 60_000).unref()
  runE2E(opts, env, realDeps(), (cancel) => (cancelNow = cancel)).then(
    (e) => process.exit(e.result === "pass" ? 0 : 1),
    (e) => {
      console.error(`machine-join-e2e: refused: ${e instanceof Error ? e.message : "error"}`)
      process.exit(2)
    }
  )
}
