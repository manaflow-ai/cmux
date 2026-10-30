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
/** After a cancel: the whole cleanup's deadline, and the part of it kept for the revoke request. */
export const CANCEL_BUDGET_MS = 7_500
export const REVOKE_RESERVE_MS = 2_500
/** After a SIGKILL, a child's result comes at most this much later, even if a descendant holds its pipes open. */
export const KILL_GRACE_MS = 500
export const CHILD_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/
const USER = /^[a-z_][a-z0-9_-]{0,31}$/
/** An id from the platform or acpmux (machine, join token, team, label): plain, short, and never token-shaped,
 * since it goes into URLs, log lines and the evidence before or without a mask. Anything else is null. */
export const safeId = (v: unknown): string | null =>
  typeof v === "string" && /^[A-Za-z0-9._-]{1,128}$/.test(v) && !/^\.+$/.test(v) && !/cm[jm]_|^eyJ|bearer/i.test(v) ? v : null

/** A log line that can start no workflow command: no `::` (v2 commands), no `##[` (v1), one line only. */
export const plainLine = (text: string) =>
  text.replace(/[\r\n]+/g, " ").replace(/:(?=:)/g, ": ").replace(/##\[/g, "## [")

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
  /** UTF-8 text; with `binary`, one character per byte (latin1). */
  stdout: string
  /** UTF-8 text. */
  stderr: string
}

/** `text`'s UTF-8 bytes, one character per byte: how a held value appears in binary (latin1) output. */
export const byteForm = (text: string) => Buffer.from(text, "utf8").toString("latin1")

export interface Daemon {
  /** Stops the process (SIGTERM, then SIGKILL) and answers what it printed. */
  stop(): Promise<ChildResult>
}

export interface Deps {
  fetch: (url: string, init: RequestInit) => Promise<Response>
  /** Runs argv with exactly `env`, writing `stdin` (then closing it) when given. */
  run(argv: string[], options: { env: Record<string, string>; stdin?: string; timeoutMs: number; signal?: AbortSignal; binary?: boolean }): Promise<ChildResult>
  /** Starts a long-running argv with exactly `env`; stdin is closed. */
  start(argv: string[], options: { env: Record<string, string> }): Daemon
  /** One line of this step's output (the job log). */
  write(line: string): void
  writeFile(path: string, text: string): void
  now(): number
  /** Resolves after `ms`; an aborted `signal` drops the timer (the promise then never settles). */
  sleep(ms: number, signal?: AbortSignal): Promise<void>
  /** A signal that aborts `ms` from now, on the same clock as `now` and `sleep`. */
  timeout(ms: number): AbortSignal
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
  list: { machineId: string | null; label: string | null; revoked: boolean; lastHeartbeatPresent: boolean } | null
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
  if (!/^\d{1,20}$/.test(opts.runId)) return "run must be the numeric run id"
  if (!USER.test(opts.user) || opts.user === "root") return "user must be a plain disposable login name"
  if (!opts.home.startsWith("/") || opts.home.includes("..")) return "home must be an absolute path"
  if (!opts.acpmux.startsWith("/")) return "acpmux must be an absolute path"
  if (!opts.evidence.startsWith("/")) return "evidence must be an absolute path"
  return undefined
}

const count = (text: string, needle: string) => text.split(needle).length - 1

export interface TarEntry {
  /** The path as archived (`./.acpmux/…`), with a GNU long name applied. */
  name: string
  /** `0` a regular file, `5` a directory, `2` a symlink, … */
  type: string
  /** A symlink's target. */
  link: string
  body: string
}

/** The entries of a GNU or ustar archive (bytes as latin1). Throws on a truncated or malformed one. */
export function tarEntries(data: string): TarEntry[] {
  const out: TarEntry[] = []
  const field = (h: string, from: number, to: number) => h.slice(from, to).split("\0")[0]!
  let longName: string | null = null
  let longLink: string | null = null
  for (let off = 0; ; ) {
    if (off + 512 > data.length) throw new Error("archive truncated")
    const h = data.slice(off, off + 512)
    if (/^\0*$/.test(h)) return out
    const sizeText = field(h, 124, 136).trim()
    if (!/^[0-7]+$/.test(sizeText)) throw new Error("archive header malformed")
    const size = parseInt(sizeText, 8)
    if (off + 512 + size > data.length) throw new Error("archive truncated")
    const body = data.slice(off + 512, off + 512 + size)
    off += 512 + Math.ceil(size / 512) * 512
    const type = h[156] === "\0" ? "0" : h[156]!
    if (type === "L") {
      longName = body.split("\0")[0]!
      continue
    }
    if (type === "K") {
      longLink = body.split("\0")[0]!
      continue
    }
    if (type === "x" || type === "g") throw new Error("pax archives are not read here")
    const prefix = h.slice(257, 262) === "ustar" ? field(h, 345, 500) : ""
    const name = longName ?? (prefix ? `${prefix}/${field(h, 0, 100)}` : field(h, 0, 100))
    out.push({ name, type, link: longLink ?? field(h, 157, 257), body })
    longName = null
    longLink = null
  }
}

/** A heartbeat time as epoch ms: a number (seconds below 1e11, else ms), a digit string the same way, or RFC 3339. */
export const heartbeatMs = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d{1,16}$/.test(v) ? Number(v) : null
  if (n !== null) return Number.isFinite(n) && n > 0 ? (n < 100_000_000_000 ? n * 1000 : n) : null
  if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(v)) return null
  const t = Date.parse(v)
  return Number.isFinite(t) ? t : null
}
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
  // A held value as JSON writes it, too: quotes, backslashes and control characters come out escaped.
  if (secrets.some((s) => s.length >= 4 && (text.includes(s) || text.includes(JSON.stringify(s).slice(1, -1))))) found.push("held secret")
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
  // Every line but this script's own commands is made plain first: an id, a server code or acpmux's
  // output can then never start a workflow command (::stop-commands:: would turn later masks into text).
  const say = (line: string) => {
    const plain = plainLine(line)
    transcript.push(plain)
    deps.write(plain)
  }
  const warn = (text: string) => {
    transcript.push(`::warning::${plainLine(text)}`)
    deps.write(`::warning::${plainLine(text)}`)
  }
  const hold = (value: string) => {
    if (!value) return
    // The runner swallows this command and hides the value everywhere after it. The value is escaped as
    // a workflow command's data (% CR LF), and each line of a multi-line value is masked on its own too.
    // Held in both forms: as text (UTF-8 child output, the log) and as its UTF-8 bytes one per character
    // (the home scan's archive), which differ for a non-ASCII value. Both are masked and matched.
    for (const form of new Set([value, byteForm(value)])) {
      deps.write(`::add-mask::${escapeData(form)}`)
      for (const line of form.split(/\r?\n|\r/)) if (line && line !== form) deps.write(`::add-mask::${escapeData(line)}`)
      secrets.push(form)
    }
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
  // Everything runs as the disposable user, reads included: a path that user controls (a symlink, say)
  // reaches nothing beyond what that user could read anyway. Nothing here runs as root.
  const asUserTool = (args: string[]) => [
    "sudo", "-n", "-u", opts.user, "--", "/usr/bin/env", "-i", "-C", opts.home,
    `HOME=${opts.home}`, `USER=${opts.user}`, `LOGNAME=${opts.user}`, `PATH=${CHILD_PATH}`, "LANG=C.UTF-8",
    ...args
  ]
  const asUser = (args: string[]) => asUserTool([opts.acpmux, ...args])
  const credentialFile = `${opts.home}/.acpmux/machine-credential.json`
  // lstat (stat without -L) of the state directory and the credential file: the user's own directory (not a
  // link, so the file is inside the home, whose root-owned parent the user cannot replace) and the user's own
  // regular file with one link (no hard link to it anywhere else).
  const credentialStat = async () => {
    const stateDir = `${opts.home}/.acpmux`
    const r = await deps.run(asUserTool(["stat", "-c", "%n|%F|%U|%h|%a", "--", stateDir, credentialFile]), { env: childEnv, timeoutMs: 10_000 })
    const [dir, file] = r.stdout.trim().split("\n").map((l) => l.split("|"))
    const own =
      r.code === 0 &&
      dir?.[0] === stateDir && dir[1] === "directory" && dir[2] === opts.user &&
      file?.[0] === credentialFile && /^regular (empty )?file$/.test(file[1] ?? "") && file[2] === opts.user && file[3] === "1"
    return { own, mode: own && /^[0-7]{3,4}$/.test(file?.[4] ?? "") ? file![4]! : null }
  }
  const acpmux = async (args: string[], stdin?: string, signal?: AbortSignal, timeoutMs = 60_000) => {
    // No new process of the disposable user once cleanup has begun (it has stopped them all).
    live()
    const r = await deps.run(asUser(args), { env: childEnv, timeoutMs, ...(stdin === undefined ? {} : { stdin }), ...(signal ? { signal } : {}) })
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
  // A cancel aborts every request in flight (cleanup's own included; it retries) and sets one absolute
  // deadline, CANCEL_BUDGET_MS after the cancel: every later request ends by it, less `reserve`, the time
  // kept back for the revoke itself. The process exits at 9 s; the runner's grace is SIGINT, then SIGTERM
  // 7.5 s later, then SIGKILL.
  let cancelled = false
  let cancelBy = Infinity
  let reserve = 0
  let inFlight = new AbortController()
  // Resolves on the cancel.
  let wake: () => void = () => undefined
  const woken = new Promise<void>((resolve) => (wake = resolve))
  /** True when `work` settles within `ms` (or before a cancel, when `interruptible`); the timer is dropped either way. */
  const within = async (work: Promise<unknown>, ms: number, interruptible: boolean) => {
    const timer = new AbortController()
    try {
      return await Promise.race([
        work.then(() => true, () => true),
        deps.sleep(ms, timer.signal).then(() => false),
        ...(interruptible ? [woken.then(() => false)] : [])
      ])
    } finally {
      timer.abort()
    }
  }
  /** Waits for `work` up to `long`; after a cancel (one landing meanwhile ends the long wait), up to `short`
   * more. A cancel shortens a wait for a process to stop; it never skips confirming that it stopped. */
  const settle = async (work: Promise<unknown>, short: number, long: number) => {
    if (!cancelled && (await within(work, long, true))) return true
    if (!cancelled) return false
    return within(work, short, false)
  }
  const left = () => cancelBy - reserve - deps.now()
  const budget = () => (cancelled ? Math.max(250, Math.min(3_000, left())) : 20_000)
  // `keep`: a cancel does not abort this request (its own timeout still bounds it), for a request whose
  // effect cleanup must know of to undo it (the install's registration).
  const call = async (url: string, init: { method: string; headers?: Record<string, string>; body?: unknown; keep?: boolean }) => {
    const res = await deps.fetch(url, {
      method: init.method,
      redirect: "error",
      signal: init.keep ? deps.timeout(budget()) : AbortSignal.any([deps.timeout(budget()), inFlight.signal]),
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
  // The sign-in, install and token stage while it runs; cleanup waits for it before undoing it.
  let authing: Promise<void> | undefined
  let keys: CryptoKeyPair | undefined
  let access: { token: string; expiresAt: number } | undefined
  let token: string | undefined
  let daemon: Daemon | undefined
  let credentialPath: string | undefined
  let machineRevoked = false
  // The join child while it runs; cleanup waits for it, since it may redeem the token at any moment.
  let joining: Promise<ChildResult> | undefined
  let joinStarted = false
  // Settles when the join's process has ended (never, if it never started); stops it on abort.
  let joinSettled: Promise<unknown> = new Promise(() => undefined)
  let joinEnded = false
  const joinStop = new AbortController()

  const op = async (name: string, params: unknown, keep = false) => {
    const r = await call(`${DEV_API}/v1/ops`, {
      method: "POST",
      headers: { authorization: `Bearer ${stack!.access}` },
      body: { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" },
      keep
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
  // `by` is an absolute deadline: each read gets only what is left of it (60 s at most), and the one retry
  // (after 1 s) runs only if more than that second is left. A read is killed at `by` and answers at most
  // KILL_GRACE_MS later (realDeps); an answer that comes after `by` does not count.
  const status = async (by = Infinity) => {
    for (let attempt = 0; ; attempt++) {
      const left = by - deps.now()
      if (left <= 0) throw new Failed("status: no time left")
      const r = await acpmux(["host", "join", "--status", "--json"], undefined, undefined, Math.min(60_000, left))
      const s = lastJson(r.stdout)
      const late = deps.now() > by
      if (r.code === 0 && s && !late) return s
      if (late || attempt >= 1 || by - deps.now() <= 1_000) throw new Failed(late ? "status: past its deadline" : `status: exit ${r.code}`)
      await within(new Promise(() => undefined), 1_000, false)
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
        const stale = safeId(m.machineId)
        if (!Number.isFinite(made) || deps.now() - made < 30 * 60_000 || !stale) continue
        const done = await platform("POST", `/v1/machines/credentials/${encodeURIComponent(stale)}/revoke`)
        if (done.status >= 200 && done.status < 300) swept += 1
      }
      if (swept > 0) say(`revoked ${swept} machine(s) an earlier interrupted run left joined`)
    } catch {
      warn("could not sweep earlier runs' machines")
    }
  }

  const revokeMachine = async () => {
    if (machineRevoked || !evidence.joinTokenId || !joinStarted) return
    // A join that failed or was interrupted after the redeem still left a machine: find it by its join
    // token, a few times, since the list may not show it at once (6 reads over about 10 s; after a
    // cancel, reads until the deadline less the revoke's reserve). The join process is already gone
    // here, so no redeem can start later.
    let machineId = evidence.machineId ?? undefined
    reserve = REVOKE_RESERVE_MS
    try {
      for (let attempt = 0; !machineId; attempt++) {
        if (cancelled ? left() < 500 : attempt >= 6) break
        // The 2 s pause between reads ends early on a cancel; after one, pauses are 0.5 s at most.
        if (attempt > 0) {
          // After a cancel, pauses of 0.5 s at most, and no read once a pause would be too short to matter
          // (no back-to-back reads as the deadline nears).
          const pause = cancelled ? Math.min(500, left() - 500) : 2_000
          if (pause < 100) break
          await within(new Promise(() => undefined), pause, !cancelled)
        }
        try {
          const found = safeId((await listEntry())?.machineId)
          if (found) machineId = found
        } catch (e) {
          // After a cancel a read cut short by its budget is not the end: read again while time remains.
          if (!cancelled) throw e
        }
      }
    } finally {
      reserve = 0
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
    deps.run(["sudo", "-n", "-u", opts.user, "--", "/bin/kill", `-${signal}`, "-1"], { env: childEnv, timeoutMs: cancelled ? 1_000 : 5_000 })

  // One pass, in this order: no new join or daemon can start (the main flow checks `cleaning`); every
  // process of the disposable user is stopped and awaited; the machine is revoked (found by its join
  // token when the join did not report it); then the run's install is revoked and the session signed out.
  let cleaning: Promise<void> | undefined
  const cleanup = () =>
    (cleaning ??= (async () => {
      const stopping = daemon?.stop()
      daemon = undefined
      if (joinStarted) {
        // The join's launcher itself (sudo relays the TERM, or ends before it starts acpmux), then every
        // process of the user. Each step is confirmed before the next, on short bounds after a cancel
        // (at most 3 s in all), so no join can still redeem once the search for its machine begins.
        joinStop.abort()
        await settle(killUser("TERM"), 750, 5_000)
        await settle(Promise.all([joinSettled, stopping]), 1_500, 10_000)
        await settle(killUser("KILL"), 750, 5_000)
        if (!joinEnded) problems.push("the join process had not stopped before the search for its machine")
      }
      if (stopping) {
        let output: ChildResult | undefined
        await settle(stopping.then((r) => (output = r)), 250, 1_000)
        if (output) childText.push(output.stdout, output.stderr)
      }
      // A cancel that lands during this pass aborts the request in flight: try again, on the cancel's budget.
      for (;;) {
        const before = cancelled
        try {
          await revokeMachine()
          // A run that failed before its own revoke check still proves the revoke here.
          if (machineRevoked && evidence.revoke.revokedListed === null && (!cancelled || left() > 1_000)) evidence.revoke.revokedListed = (await listEntry())?.revoked === true
          break
        } catch (e) {
          if (cancelled && !before && !machineRevoked) continue
          problems.push(e instanceof Failed ? e.message : "revoke failed")
          break
        }
      }
      if (evidence.joinTokenId && joinStarted && !machineRevoked && !evidence.machineId) say("no machine was listed for this join token; nothing to revoke")
      // The auth stage (a registration in flight survives a cancel) gets what is left of the cancel budget,
      // less 1.5 s for the install's revoke and the sign-out. Its private key never leaves this process, so
      // an install whose answer never comes cannot be used.
      if (authing) await settle(authing, Math.max(250, cancelBy - deps.now() - 1_500), 20_000)
      if (install && stack) {
        await op("install.revoke", { install }).then(
          () => say("revoked the run's cmux install"),
          () => warn("could not revoke the run's cmux install")
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
    if (!cancelled) {
      cancelled = true
      cancelBy = deps.now() + CANCEL_BUDGET_MS
      problems.push("cancelled")
    }
    inFlight.abort()
    inFlight = new AbortController()
    wake()
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

    // 1. Stack sign-in (development project), cmux user, a throwaway install and its access token. Cleanup
    // waits for this (bounded) before it revokes the install and signs out, so a late answer is still undone;
    // after each stage the flow stops if cleanup has begun.
    authing = (async () => {
      const signIn = await call(`${STACK_API}/auth/password/sign-in`, { method: "POST", headers: stackHeaders(), body: { email, password } })
      for (const key of ["access_token", "refresh_token"]) if (typeof signIn.json?.[key] === "string") hold(signIn.json[key])
      if (signIn.status !== 200 || typeof signIn.json?.access_token !== "string") throw refusedBy("stack sign-in", signIn)
      stack = { access: signIn.json.access_token, refresh: String(signIn.json.refresh_token ?? "") }
      say("signed in to the development stack project")
      live()
      user = String((await op("user.ensure", {}))?.id ?? "")
      live()
      keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair
      const jwk = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey
      live()
      install = String(
        (await op("install.register", {
          public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
          kind: "cli",
          name: `machine-join-e2e ${opts.runId}`.slice(0, 80),
          device_name: "machine-join-e2e runner",
          platform: "linux"
          // Kept through a cancel: cleanup must learn the install's id to revoke it.
        }, true))?.id ?? ""
      )
      live()
      await accessToken()
    })()
    await authing
    say("cmux-api-development access token ready")
    live()
    await sweepStale()

    // 2. Mint.
    live()
    // The label is always the run's (the sweep finds a killed run's machine by it); the name is free.
    const mint = await platform("POST", "/v1/machines/join-tokens", { label: `ci-join-${opts.runId}`, ttlSeconds: 600 })
    if (typeof mint.json?.token === "string") hold(mint.json.token)
    if (mint.status !== 200 || typeof mint.json?.token !== "string" || !/^cmj_[A-Za-z0-9_-]{16,4096}$/.test(mint.json.token)) throw refusedBy("mint", mint)
    token = mint.json.token as string
    evidence.joinTokenId = safeId(mint.json.joinTokenId)
    evidence.teamId = safeId(mint.json.teamId)
    // Without its id, a joined machine could not be found to revoke: never join then.
    if (!evidence.joinTokenId || !evidence.teamId) throw new Failed("mint: no joinTokenId or teamId")
    say(`minted join token ${evidence.joinTokenId} for team ${evidence.teamId}`)

    // 3. Join: the token goes to stdin only, then this process drops it.
    live()
    joinStarted = true
    joining = acpmux(["host", "join", "--hub", opts.origin, "--name", opts.name, "--json"], `${token}\n`, joinStop.signal)
    joinSettled = joining.then(
      () => (joinEnded = true),
      () => (joinEnded = true)
    )
    token = undefined
    const joined = await joining
    joining = undefined
    const j = lastJson(joined.stdout)
    if (joined.code !== 0 || j?.joined !== true) {
      const meaning: Record<number, string> = { 2: "malformed", 3: "expired or used", 4: "hub unreachable", 5: "store failed" }
      throw new Failed(`join: exit ${joined.code}${joined.code !== null && meaning[joined.code] ? ` (${meaning[joined.code]})` : ""}`)
    }
    evidence.machineId = safeId(j.machineId)
    if (!evidence.machineId) throw new Failed("join: no valid machineId")
    expect(j.teamId === evidence.teamId, "join team differs from the mint's team")
    say(`joined as machine ${evidence.machineId}`)

    // The stored credential is masked before anything else could print it.
    const pre = await status()
    if (pre.credentialPath !== credentialFile) throw new Failed("status: credential path is not the disposable home's credential file")
    credentialPath = credentialFile
    // The user's own regular file (not a link), read as that user.
    const before = await credentialStat()
    if (!before.own) throw new Failed("credential file is not the disposable user's own regular file, with one link, in its own state directory")
    evidence.credentialFileMode = before.mode
    // 600 from the join itself, not only once the daemon has rewritten the file: a failure here stands.
    expect(before.mode === "600", "credential file mode is not 600 after the join")
    const file = await deps.run(asUserTool(["cat", "--", credentialPath]), { env: childEnv, timeoutMs: 10_000 })
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
    const daemonStartedAt = deps.now()
    daemon = deps.start(asUser(["daemon", "run"]), { env: childEnv })
    const deadline = deps.now() + HEARTBEAT_LIMIT_S * 1000
    let s: any = pre
    let strangeBeat = false
    for (;;) {
      // Status reads (and their retry) end by the heartbeat deadline, so a slow one cannot carry the check past it.
      if (deadline - deps.now() <= 0) break
      s = await status(deadline)
      // acpmux records ms since the epoch on this machine's clock (a string): a beat counts only when it
      // falls in this daemon's first HEARTBEAT_LIMIT_S (1 s of slack before its start), and not in the future.
      const beat = typeof s.lastHeartbeat === "string" && /^\d{1,16}$/.test(s.lastHeartbeat) ? Number(s.lastHeartbeat) : NaN
      if (Number.isFinite(beat) && beat >= daemonStartedAt - 1_000 && beat <= Math.min(deadline, deps.now() + 5_000)) {
        evidence.status.heartbeatAgeSeconds = Math.max(0, Math.round((deps.now() - beat) / 1000))
        if (evidence.status.heartbeatAgeSeconds < HEARTBEAT_LIMIT_S) break
      } else if (s.lastHeartbeat !== null && s.lastHeartbeat !== undefined) strangeBeat = true
      if (deps.now() >= deadline) break
      // The pause ends by the deadline too.
      const pause = Math.min(3_000, deadline - deps.now())
      if (pause <= 0) break
      await within(new Promise(() => undefined), pause, false)
    }
    evidence.status.credentialPresent = s.credentialPresent === true
    evidence.status.joinIncomplete = s.joinIncomplete === true
    evidence.status.revoked = s.revoked === true
    evidence.status.hubReachable = s.hubReachable === true
    // Only the two values acpmux defines; anything else is recorded as null (and fails the consent check).
    const consentValue = (v: unknown) => (v === "none" || v === "granted" ? v : null)
    evidence.consent = { screen: consentValue(s.consent?.screen), control: consentValue(s.consent?.control) }
    expect(evidence.status.credentialPresent, "status: no credential")
    expect(!evidence.status.joinIncomplete, "status: join incomplete")
    expect(!evidence.status.revoked, "status: revoked before the revoke")
    expect(evidence.status.hubReachable, "status: hub unreachable")
    expect(evidence.status.heartbeatAgeSeconds !== null && evidence.status.heartbeatAgeSeconds < HEARTBEAT_LIMIT_S, `no heartbeat within ${HEARTBEAT_LIMIT_S} s${strangeBeat ? " (status showed a heartbeat time outside the daemon's run)" : ""}`)
    expect(s.machineId === evidence.machineId, "status: machine differs from the join's")
    expect(evidence.consent.screen === "none" && evidence.consent.control === "none", "consent is not none for both screen and control")

    // 5. The platform's list, by join token id. Its heartbeat (RFC 3339, or epoch s or ms) must fall in the
    // daemon's run, with a minute's slack for the platform's clock.
    const listedBeatFresh = (v: unknown) => {
      const t = heartbeatMs(v)
      return t !== null && t >= daemonStartedAt - 60_000 && t <= deps.now() + 60_000
    }
    const row = await listEntry()
    if (row) evidence.list = { machineId: safeId(row.machineId), label: safeId(row.label), revoked: row.revoked === true, lastHeartbeatPresent: listedBeatFresh(row.lastHeartbeat) }
    expect(evidence.list?.machineId === evidence.machineId, "list: no entry for this join token")
    expect(evidence.list?.revoked === false, "list: revoked before the revoke")
    expect(evidence.list?.lastHeartbeatPresent === true, "list: no heartbeat")

    // 6. Credential file mode, after the daemon's heartbeat writes: still the user's own regular file.
    const now = await credentialStat()
    evidence.credentialFileMode = now.own ? now.mode : null
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
    // One process with a fixed argv archives the whole home (names, link targets and contents), so no
    // file name ever reaches an argv. Incomplete is a failure: tar must read everything and exit 0.
    const archive = await deps.run(asUserTool(["tar", "-C", opts.home, "--one-file-system", "--format=gnu", "-cf", "-", "."]), { env: childEnv, timeoutMs: 30_000, binary: true })
    // tar skips what it cannot archive (a socket, say) with only a warning and exit 0: any word on stderr
    // means the archive is not the whole home.
    if (archive.code !== 0 || archive.stderr.trim() !== "") throw new Error("tar failed or skipped an entry")
    let cmj = 0
    let cmm = 0
    let held = 0
    const credentialEntry = `./${credentialFile.slice(opts.home.length + 1)}`
    for (const entry of tarEntries(archive.stdout)) {
      const meta = `${entry.name}\n${entry.link}`
      cmj += count(meta, "cmj_") + count(entry.body, "cmj_")
      cmm += count(meta, "cmm_")
      if (entry.name === credentialEntry && credentialPath) evidence.secretScan.home.credentialFileCmm = count(entry.body, "cmm_")
      else cmm += count(entry.body, "cmm_")
      // Names and bodies are bytes here: `secrets` holds each value's byte form too (see hold).
      for (const v of secrets) if (v.length >= 8 && !v.startsWith("cmm_") && (meta.includes(v) || entry.body.includes(v))) held += 1
    }
    evidence.secretScan.home.cmj = cmj
    evidence.secretScan.home.cmm = cmm
    if (held > 0) problems.push("the home holds a value of this run's sign-in or tokens")
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
  const collect = (argv: string[], env: Record<string, string>, stdin: string | undefined, binary = false) => {
    const child = spawn(argv[0]!, argv.slice(1), { env, cwd: "/", stdio: ["pipe", "pipe", "pipe"] })
    const out: Buffer[] = []
    const err: Buffer[] = []
    child.stdout.on("data", (b: Buffer) => out.push(b))
    child.stderr.on("data", (b: Buffer) => err.push(b))
    child.stdin.on("error", () => undefined)
    if (stdin !== undefined) child.stdin.write(stdin)
    child.stdin.end()
    // Text is UTF-8, as acpmux and the tools print it, so redaction and masks see the original values;
    // binary output (the scan's archive) keeps every byte as one character.
    const result = (code: number | null): ChildResult => ({
      code,
      stdout: Buffer.concat(out).toString(binary ? "latin1" : "utf8"),
      stderr: Buffer.concat(err).toString("utf8")
    })
    let finish: (r: ChildResult) => void = () => undefined
    const done = new Promise<ChildResult>((resolve) => {
      finish = resolve
      child.on("error", () => resolve({ code: null, stdout: "", stderr: "spawn failed" }))
      child.on("close", (code) => resolve(result(code)))
    })
    // SIGKILL reaches only the launcher (sudo cannot relay it; the user's processes are ended by cleanup's
    // `kill -1` as that user). A descendant may still hold the pipes open, so the result is given at most
    // KILL_GRACE_MS later regardless, as killed (code null), and the pipes are let go.
    const kill = () => {
      child.kill("SIGKILL")
      const grace = setTimeout(() => {
        child.stdout.destroy()
        child.stderr.destroy()
        finish(result(null))
      }, KILL_GRACE_MS)
      void done.then(() => clearTimeout(grace))
    }
    return { child, done, kill }
  }
  return {
    fetch: (url, init) => fetch(url, init),
    run: async (argv, { env, stdin, timeoutMs, signal, binary }) => {
      const { child, done, kill } = collect(argv, env, stdin, binary)
      // The result comes by timeoutMs + KILL_GRACE_MS at the latest.
      const timer = setTimeout(kill, timeoutMs)
      // An abort: SIGTERM (sudo relays it to its command), then SIGKILL a second later.
      let hard: ReturnType<typeof setTimeout> | undefined
      const stop = () => {
        child.kill("SIGTERM")
        hard = setTimeout(kill, 1_000)
      }
      if (signal?.aborted) stop()
      else signal?.addEventListener("abort", stop, { once: true })
      try {
        return await done
      } finally {
        clearTimeout(timer)
        if (hard) clearTimeout(hard)
        signal?.removeEventListener("abort", stop)
      }
    },
    start: (argv, { env }) => {
      const { child, done, kill } = collect(argv, env, undefined)
      return {
        stop: async () => {
          // sudo relays SIGTERM to acpmux; the job's cleanup step kills the user's leftovers.
          child.kill("SIGTERM")
          const hard = setTimeout(kill, 10_000)
          try {
            return await done
          } finally {
            clearTimeout(hard)
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
    sleep: (ms, signal) =>
      new Promise((resolve) => {
        const t = setTimeout(resolve, ms)
        signal?.addEventListener("abort", () => clearTimeout(t), { once: true })
      }),
    timeout: (ms) => AbortSignal.timeout(ms)
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
