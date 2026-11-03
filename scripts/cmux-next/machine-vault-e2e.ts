#!/usr/bin/env bun
/**
 * "Make this Mac a cmux machine", with the vault, end to end on the DEVELOPMENT platform, for
 * .github/workflows/machine-vault-e2e.yml.
 *
 *   bun scripts/cmux-next/machine-vault-e2e.ts --origin https://cmux-platform-development.debussy.workers.dev \
 *     --cmux PATH --user USER --home DIR --ssh PATH --name NAME --work DIR --evidence FILE --run ID --sha SHA
 *
 * The stack account comes only from this process's environment (CMUX_UITEST_STACK_EMAIL and
 * CMUX_UITEST_STACK_PASSWORD, the repo's dev stack pair) and, optionally, CMUX_E2E_ANTHROPIC_API_KEY.
 * This process signs in, gets a cmux-api-development access token and writes it to one 0600 file in
 * `--work` (a 0700 directory in the runner's temp) for the CLI's `--cloud-token-file`; the file is
 * removed in `finally`. Every held value is masked (::add-mask::) the moment it exists, children get
 * a fixed environment, no argv carries a secret, and vault values reach the CLI on stdin only.
 *
 * Steps, each a real command a person runs:
 *   1. `cmux machine vault set MACHINE_VAULT_E2E` (a random nonce on stdin), and when the API key is
 *      given, `cmux machine vault set ANTHROPIC_API_KEY` (stdin).
 *   2. `cmux machine add --vault --yes USER@localhost`: the token reaches the new user's shell on
 *      ssh's stdin, the served join.sh installs acpmux, Claude Code and Codex and pulls the vault.
 *   3. As that user: acpmux has `machine.vault.pull.v1` (else the channel is too old: refused),
 *      `acpmux machine vault status --json` lists MACHINE_VAULT_E2E in the keychain.
 *   4. With the API key: a Claude Code session through acpmux runs `printenv MACHINE_VAULT_E2E`;
 *      the pass is its reply equal to the nonce. Without the key this part is skipped and the
 *      evidence says so (the run fails: a skip is never a pass).
 *   5. Cleanup in `finally` and on SIGINT/SIGTERM: the user's processes, the machine revoke (every
 *      machine labelled with this run's name), the vault entries this run set, the install revoke,
 *      the sign-out, the token file. Then a secret scan of the disposable home and the output.
 * Exit 0 when the evidence says pass, 1 otherwise, 2 for a refused invocation.
 */
import { spawn } from "node:child_process"
import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { byteForm, escapeData, evidenceLeaks, plainLine, redact, safeId, tarEntries } from "./machine-join-e2e.ts"

export const DEV_PLATFORM = "https://cmux-platform-development.debussy.workers.dev"
export const DEV_API = "https://cmux-api-development.debussy.workers.dev"
const STACK_API = "https://api.stack-auth.com/api/v1"
// The development Stack project cmux-api-development trusts, and its public client key (as machine-join-e2e.ts).
const DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
const DEV_STACK_CLIENT_KEY = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
const USER_AGENT = "cmux-machine-vault-e2e/1"
/** The vault var this run proves. Not CMUX_*: the vault refuses names cmux owns. */
export const NONCE_VAR = "MACHINE_VAULT_E2E"
export const KEY_VAR = "ANTHROPIC_API_KEY"
export const VAULT_CAPABILITY = "machine.vault.pull.v1"
export const PROMPT = `Run \`printenv ${NONCE_VAR}\` and reply with exactly its output.`
/** After a SIGKILL, a child's result comes at most this much later. */
export const KILL_GRACE_MS = 500
export const CHILD_PATH = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
const NAME = /^ci-vault-\d{1,20}(?:-\d{1,4})?$/
const USER = /^[a-z_][a-z0-9_-]{0,31}$/

export interface Options {
  origin: string
  cmux: string
  user: string
  home: string
  ssh: string
  name: string
  work: string
  evidence: string
  runId: string
  sha: string
}

export interface ChildResult {
  code: number | null
  stdout: string
  stderr: string
}

export interface Deps {
  fetch: (url: string, init: RequestInit) => Promise<Response>
  /** Runs argv with exactly `env`, writing `stdin` (then closing it) when given. */
  /** An aborted `signal` kills the child (SIGTERM, then SIGKILL); the result still comes. */
  run(argv: string[], options: { env: Record<string, string>; stdin?: string; timeoutMs: number; binary?: boolean; signal?: AbortSignal }): Promise<ChildResult>
  write(line: string): void
  /** Writes `text` to a new file with mode 0600. */
  writeFile(path: string, text: string): void
  removeFile(path: string): void
  now(): number
  random(): string
}

export interface Evidence {
  run: { id: string; sha: string }
  hubOrigin: string
  name: string
  user: string
  nonce: string | null
  vaultSet: { nonce: boolean; anthropicKey: "set" | "kept-existing" | "skipped" | "failed" }
  join: { exit: number | null; joinTokenId: string | null; machineId: string | null }
  acpmuxCapability: boolean | null
  vaultStatus: { env: string[]; secretStore: string | null; joined: boolean | null; lastResult: string | null } | null
  agentReply: "pass" | "mismatch" | "failed" | "skipped (no CMUX_E2E_ANTHROPIC_API_KEY)" | null
  secretScan: { home: { held: number | null; cmj: number | null }; log: { held: number; cmj: number } }
  cleanup: { machinesRevoked: number; vaultRemoved: string[]; installRevoked: boolean | null; tokenFileRemoved: boolean }
  result: "pass" | "fail"
  reason: string
}

class Refused extends Error {}
class Failed extends Error {}

export function refusal(opts: Options): string | undefined {
  if (opts.origin !== DEV_PLATFORM) return `origin must be ${DEV_PLATFORM}`
  if (!NAME.test(opts.name)) return "name must be ci-vault-<run id>"
  if (!/^\d{1,20}$/.test(opts.runId)) return "run must be the numeric run id"
  if (!USER.test(opts.user) || opts.user === "root") return "user must be a plain disposable login name"
  for (const [flag, path] of [["home", opts.home], ["cmux", opts.cmux], ["ssh", opts.ssh], ["work", opts.work], ["evidence", opts.evidence]] as const) {
    if (!path.startsWith("/") || path.includes("..")) return `${flag} must be an absolute path`
  }
  return undefined
}

const count = (text: string, needle: string) => text.split(needle).length - 1

/** The last JSON object a CLI printed on stdout (one line each, or one pretty object). */
export function lastJson(text: string): any {
  const lines = text.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("{"))
  for (const line of lines.reverse()) {
    try {
      return JSON.parse(line)
    } catch {}
  }
  const start = text.indexOf("{")
  if (start < 0) return undefined
  try {
    return JSON.parse(text.slice(start))
  } catch {
    return undefined
  }
}

/** The reply text of `acpmux --json run`: its `reply`, trimmed. */
export function replyText(stdout: string): string | null {
  const reply = lastJson(stdout)?.reply
  return typeof reply === "string" ? reply.trim() : null
}

export async function runE2E(
  opts: Options,
  env: Record<string, string | undefined>,
  deps: Deps,
  onCancel?: (cancel: () => Promise<void>) => void
): Promise<Evidence> {
  const secrets: string[] = []
  const transcript: string[] = []
  const childText: string[] = []
  const say = (line: string) => {
    const plain = plainLine(redact(line, secrets))
    transcript.push(plain)
    deps.write(plain)
  }
  const hold = (value: string) => {
    if (!value) return
    for (const form of new Set([value, byteForm(value)])) {
      deps.write(`::add-mask::${escapeData(form)}`)
      secrets.push(form)
    }
  }
  const evidence: Evidence = {
    run: { id: opts.runId, sha: opts.sha },
    hubOrigin: opts.origin,
    name: opts.name,
    user: opts.user,
    nonce: null,
    vaultSet: { nonce: false, anthropicKey: "skipped" },
    join: { exit: null, joinTokenId: null, machineId: null },
    acpmuxCapability: null,
    vaultStatus: null,
    agentReply: null,
    secretScan: { home: { held: null, cmj: null }, log: { held: 0, cmj: 0 } },
    cleanup: { machinesRevoked: 0, vaultRemoved: [], installRevoked: null, tokenFileRemoved: false },
    result: "fail",
    reason: ""
  }
  const problems: string[] = []
  const expect = (ok: boolean, what: string) => {
    if (!ok) problems.push(what)
    return ok
  }

  const tokenFile = join(opts.work, "cloud-token")
  const cliHome = join(opts.work, "home")
  // The runner side: the CLI with a private HOME, the ssh wrapper's directory first on PATH.
  const cliEnv = { PATH: `${dirname(opts.ssh)}:${CHILD_PATH}`, HOME: cliHome, LANG: "C.UTF-8", CMUX_PLATFORM_URL: opts.origin }
  // Everything the main flow starts (a request, a child) is tracked: cleanup stops the children, then
  // waits for every tracked piece to settle before it undoes anything, so nothing the main flow had in
  // flight (a vault write, a registration, the join) lands after cleanup looked. Cleanup's own calls
  // pass `own` and are neither tracked nor refused.
  const pending = new Set<Promise<unknown>>()
  const stopChildren = new AbortController()
  const track = <T>(work: Promise<T>): Promise<T> => {
    pending.add(work)
    work.then(() => pending.delete(work), () => pending.delete(work))
    return work
  }
  const settlePending = async () => {
    while (pending.size > 0) await Promise.allSettled([...pending])
  }
  const cli = async (args: string[], stdin?: string, timeoutMs = 60_000, own = false) => {
    if (!own) live()
    const work = deps.run([opts.cmux, ...args, "--cloud-token-file", tokenFile], {
      env: cliEnv,
      timeoutMs,
      ...(stdin === undefined ? {} : { stdin }),
      ...(own ? {} : { signal: stopChildren.signal })
    })
    const r = await (own ? work : track(work))
    childText.push(r.stdout, r.stderr)
    return r
  }
  // The disposable user's side: sudo -n -u USER env -i, a login-like environment and nothing else,
  // through zsh so the user's ~/.zshenv (the workflow's: it unlocks the login keychain) runs first,
  // as it does for the ssh session the join ran in.
  const userPath = `${opts.home}/.local/bin:${opts.home}/.cmux/bin:/opt/homebrew/bin:${CHILD_PATH}`
  const asUser = (args: string[]) => [
    "sudo", "-n", "-u", opts.user, "--", "/usr/bin/env", "-i",
    `HOME=${opts.home}`, `USER=${opts.user}`, `LOGNAME=${opts.user}`, `PATH=${userPath}`, "LANG=C.UTF-8", "SHELL=/bin/zsh",
    "/bin/zsh", "-c", 'cd && exec "$@"', "zsh",
    ...args
  ]
  const userRun = async (args: string[], timeoutMs = 60_000, binary = false, own = false) => {
    if (!own) live()
    const work = deps.run(asUser(args), { env: { PATH: CHILD_PATH }, timeoutMs, binary, ...(own ? {} : { signal: stopChildren.signal }) })
    const r = await (own ? work : track(work))
    if (!binary) childText.push(r.stdout, r.stderr)
    return r
  }
  const acpmux = `${opts.home}/.local/bin/acpmux`

  const call = async (url: string, init: { method: string; headers?: Record<string, string>; body?: unknown }, own = false) => {
    if (!own) live()
    return own ? request(url, init) : track(request(url, init))
  }
  const request = async (url: string, init: { method: string; headers?: Record<string, string>; body?: unknown }) => {
    const res = await deps.fetch(url, {
      method: init.method,
      redirect: "error",
      signal: AbortSignal.timeout(20_000),
      headers: { "user-agent": USER_AGENT, ...(init.body === undefined ? {} : { "content-type": "application/json" }), ...init.headers },
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) })
    })
    const json = (await res.json().catch(() => ({}))) as any
    return { status: res.status, json }
  }
  const refusedBy = (step: string, r: { status: number; json: any }) => {
    const code = [r.json?.code, r.json?.error?.code].find((c) => typeof c === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(c))
    return new Failed(`${step}: HTTP ${r.status}${code ? ` ${code}` : ""}`)
  }
  const stackHeaders = () => ({ "x-stack-project-id": DEV_STACK_PROJECT, "x-stack-publishable-client-key": DEV_STACK_CLIENT_KEY, "x-stack-access-type": "client" })

  let stack: { access: string; refresh: string } | undefined
  let user: string | undefined
  let install: string | undefined
  let keys: CryptoKeyPair | undefined
  let access: { token: string; expiresAt: number } | undefined
  let tokenWritten = false
  let addStarted = false
  // A name goes here before its write starts: cleanup removes it whether or not the write finished.
  const vaultAttempted: string[] = []

  const op = async (name: string, params: unknown, own = false) => {
    const r = await call(`${DEV_API}/v1/ops`, {
      method: "POST",
      headers: { authorization: `Bearer ${stack!.access}` },
      body: { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" }
    }, own)
    if (r.status !== 200 || r.json?.ok !== true) throw refusedBy(name, r)
    return r.json.value
  }
  const accessToken = async (own = false) => {
    if (access && access.expiresAt - deps.now() > 60_000) return access.token
    const ch = await call(`${DEV_API}/v1/auth/challenge`, { method: "POST", body: { user, install } }, own)
    if (ch.status !== 200 || typeof ch.json?.nonce !== "string") throw refusedBy("auth challenge", ch)
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys!.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const tok = await call(`${DEV_API}/v1/auth/token`, { method: "POST", body: { user, install, nonce: ch.json.nonce, signature: Buffer.from(signature).toString("base64url") } }, own)
    if (typeof tok.json?.access_token === "string") hold(tok.json.access_token)
    if (tok.status !== 200 || typeof tok.json?.access_token !== "string") throw refusedBy("auth token", tok)
    access = { token: tok.json.access_token, expiresAt: Number(tok.json.expires_at) || deps.now() + 300_000 }
    return access.token
  }
  const platform = async (method: string, path: string, own = false) =>
    call(`${opts.origin}${path}`, { method, headers: { authorization: `Bearer ${await accessToken(own)}` } }, own)
  /** The token file, fresh: the CLI reads it on each command. */
  const writeToken = async (own = false) => {
    deps.writeFile(tokenFile, `${await accessToken(own)}\n`)
    tokenWritten = true
  }

  /** Revokes every live machine labelled with this run's name, and this account's earlier CI vault
   * machines (ci-vault-<digits>) still live 30 minutes after they were made. */
  const revokeMachines = async () => {
    const r = await platform("GET", "/v1/machines/credentials", true)
    if (r.status !== 200 || !Array.isArray(r.json?.machines)) throw refusedBy("list", r)
    for (const m of r.json.machines as any[]) {
      if (m?.revoked !== false) continue
      const label = String(m?.label ?? "")
      const made = Date.parse(String(m?.createdAt ?? ""))
      const ours = label === opts.name || (evidence.join.joinTokenId !== null && m?.joinTokenId === evidence.join.joinTokenId)
      const stale = m?.mintedBy === user && /^ci-vault-\d+(?:-\d+)?$/.test(label) && Number.isFinite(made) && deps.now() - made > 30 * 60_000
      const id = safeId(m?.machineId)
      if (!(ours || stale) || !id) continue
      const done = await platform("POST", `/v1/machines/credentials/${encodeURIComponent(id)}/revoke`, true)
      if (done.status >= 200 && done.status < 300) {
        evidence.cleanup.machinesRevoked += 1
        say(`revoked machine ${id}${ours ? "" : " (left by an earlier run)"}`)
      } else if (ours) problems.push(`revoke ${id}: HTTP ${done.status}`)
    }
  }

  // One pass; every step it needs is required: a failure in any fails the run.
  let cleaning: Promise<void> | undefined
  const cleanup = () =>
    (cleaning ??= (async () => {
      // Stop the main flow's children (the join's ssh, the agent) and the user's processes, then wait for
      // every request and child the main flow had in flight, so nothing it started lands after this.
      stopChildren.abort()
      await deps.run(["sudo", "-n", "-u", opts.user, "--", "/bin/kill", "-KILL", "-1"], { env: { PATH: CHILD_PATH }, timeoutMs: 5_000 }).catch(() => undefined)
      await settlePending()
      // A cancel after a vault write or the registration started but before it answered left `stack` and
      // `install` set by now (the tracked promise settled first), so they are undone below.
      if (stack && install) {
        if (addStarted) await revokeMachines().catch((e) => problems.push(e instanceof Failed ? e.message : "machine revoke failed"))
        if (vaultAttempted.length > 0) {
          try {
            await writeToken(true)
            for (const name of vaultAttempted) await cli(["machine", "vault", "rm", name], undefined, 60_000, true)
            // The proof is the list, not rm's exit: a write that never landed has nothing to remove.
            const after = await cli(["--json", "machine", "vault", "ls"], undefined, 60_000, true)
            const rows = lastJson(after.stdout)?.entries
            if (after.code !== 0 || !Array.isArray(rows)) throw new Failed("vault ls after cleanup failed")
            const left = new Set<string>(rows.map((e: any) => String(e?.name ?? "")))
            evidence.cleanup.vaultRemoved = vaultAttempted.filter((n) => !left.has(n))
            for (const name of vaultAttempted) if (left.has(name)) problems.push(`vault entry ${name} is still in the vault after cleanup`)
          } catch (e) {
            problems.push(e instanceof Failed ? e.message : "vault cleanup failed")
          }
        }
      }
      if (tokenWritten) {
        try {
          deps.removeFile(tokenFile)
          evidence.cleanup.tokenFileRemoved = true
        } catch {
          problems.push("could not remove the token file")
        }
      }
      if (install && stack) {
        evidence.cleanup.installRevoked = await op("install.revoke", { install }, true).then(() => true, () => false)
        if (!evidence.cleanup.installRevoked) problems.push("could not revoke the run's cmux install")
      }
      if (stack) {
        await call(`${STACK_API}/auth/sessions/current`, {
          method: "DELETE",
          headers: { ...stackHeaders(), "x-stack-access-token": stack.access, "x-stack-refresh-token": stack.refresh }
        }, true).catch(() => undefined)
      }
    })())
  onCancel?.(() => {
    problems.push("cancelled")
    return cleanup()
  })
  const live = () => {
    if (cleaning) throw new Failed("cancelled before the next step")
  }

  try {
    const why = refusal(opts)
    if (why) throw new Refused(why)
    const email = env.CMUX_UITEST_STACK_EMAIL ?? ""
    const password = env.CMUX_UITEST_STACK_PASSWORD ?? ""
    const apiKey = env.CMUX_E2E_ANTHROPIC_API_KEY ?? ""
    if (!email || !password) throw new Refused("CMUX_UITEST_STACK_EMAIL and CMUX_UITEST_STACK_PASSWORD must be set")
    hold(email)
    hold(password)
    hold(apiKey)

    // 0. Sign in (development stack), a throwaway install and its cmux access token.
    const signIn = await call(`${STACK_API}/auth/password/sign-in`, { method: "POST", headers: stackHeaders(), body: { email, password } })
    for (const key of ["access_token", "refresh_token"]) if (typeof signIn.json?.[key] === "string") hold(signIn.json[key])
    if (signIn.status !== 200 || typeof signIn.json?.access_token !== "string") throw refusedBy("stack sign-in", signIn)
    stack = { access: signIn.json.access_token, refresh: String(signIn.json.refresh_token ?? "") }
    live()
    user = String((await op("user.ensure", {}))?.id ?? "")
    keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey
    live()
    install = String(
      (await op("install.register", {
        public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
        kind: "cli",
        name: `machine-vault-e2e ${opts.runId}`.slice(0, 80),
        device_name: "machine-vault-e2e runner",
        platform: "macos"
      }))?.id ?? ""
    )
    await writeToken()
    say("signed in to the development platform")

    // 1. The vault: the nonce, and the API key when given (never over an entry this run did not make).
    live()
    const nonce = deps.random()
    evidence.nonce = nonce
    const listed = await cli(["--json", "machine", "vault", "ls"])
    if (listed.code !== 0) throw new Failed(`vault ls: exit ${listed.code}`)
    const rows = lastJson(listed.stdout)?.entries
    const existing = new Set<string>((Array.isArray(rows) ? rows : []).map((e: any) => String(e?.name ?? "")))
    // The nonce's name is this harness's own: an entry already there is another run's (the workflow
    // serializes dispatches) or a killed run's leftover. Never overwrite it, never delete it.
    if (existing.has(NONCE_VAR)) {
      throw new Failed(`${NONCE_VAR} is already in this account's vault (another run, or a killed run's leftover): left as it is; remove it with cmux machine vault rm ${NONCE_VAR} once no run is going`)
    }
    live()
    vaultAttempted.push(NONCE_VAR)
    const setNonce = await cli(["machine", "vault", "set", NONCE_VAR], `${nonce}\n`)
    if (setNonce.code !== 0) throw new Failed(`vault set ${NONCE_VAR}: exit ${setNonce.code}`)
    evidence.vaultSet.nonce = true
    say(`vault: set ${NONCE_VAR}`)
    if (apiKey) {
      if (existing.has(KEY_VAR)) {
        evidence.vaultSet.anthropicKey = "kept-existing"
        say(`vault: ${KEY_VAR} is already in this account's vault; left as it is`)
      } else {
        live()
        vaultAttempted.push(KEY_VAR)
        const setKey = await cli(["machine", "vault", "set", KEY_VAR], `${apiKey}\n`)
        if (setKey.code === 0) {
          evidence.vaultSet.anthropicKey = "set"
          say(`vault: set ${KEY_VAR}`)
        } else {
          evidence.vaultSet.anthropicKey = "failed"
          problems.push(`vault set ${KEY_VAR}: exit ${setKey.code}`)
        }
      }
    }

    // 2. The one command.
    live()
    await writeToken()
    addStarted = true
    const add = await cli(["--json", "machine", "add", "--vault", "--yes", "--name", opts.name, `${opts.user}@localhost`], undefined, 20 * 60_000)
    evidence.join.exit = add.code
    const joined = lastJson(add.stdout)
    evidence.join.joinTokenId = safeId(joined?.joinTokenId)
    evidence.join.machineId = safeId(joined?.joined?.machineId)
    if (add.code !== 0) throw new Failed(`machine add: exit ${add.code}`)
    say(`machine add: joined ${evidence.join.machineId ?? "(not listed yet)"}`)

    // 3. The joined machine's vault, as the user.
    live()
    const caps = await userRun([acpmux, "capabilities"])
    evidence.acpmuxCapability = caps.code === 0 && caps.stdout.split("\n").some((l) => l.trim() === VAULT_CAPABILITY)
    if (!evidence.acpmuxCapability) throw new Failed(`the installed acpmux lacks ${VAULT_CAPABILITY}: its channel predates the vault (cmux#33020)`)
    const status = await userRun([acpmux, "--json", "machine", "vault", "status"])
    const s = lastJson(status.stdout)
    evidence.vaultStatus = {
      env: Array.isArray(s?.env) ? (s.env as any[]).map((e) => String(e?.name ?? "")).filter((n) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(n)) : [],
      secretStore: typeof s?.secretStore === "string" ? s.secretStore.replace(/[^a-z-]/g, "") : null,
      joined: typeof s?.joined === "boolean" ? s.joined : null,
      lastResult: typeof s?.lastResult === "string" ? s.lastResult.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 64) : null
    }
    expect(status.code === 0, `vault status: exit ${status.code}`)
    expect(evidence.vaultStatus.joined === true, "vault status: not joined")
    expect(evidence.vaultStatus.secretStore === "keychain", "vault status: the secret store is not the keychain")
    expect(evidence.vaultStatus.env.includes(NONCE_VAR), `vault status: ${NONCE_VAR} is not on the machine`)

    // 4. A Claude Code agent through acpmux reads it.
    live()
    if (!apiKey) {
      evidence.agentReply = "skipped (no CMUX_E2E_ANTHROPIC_API_KEY)"
      deps.write("::notice::the agent part was skipped: the CMUX_E2E_ANTHROPIC_API_KEY secret is empty, so no Claude Code session ran")
      problems.push("agent part skipped (no CMUX_E2E_ANTHROPIC_API_KEY)")
    } else {
      const run = await userRun(
        [acpmux, "--json", "run", "-m", "claude", "--policy", "approve-all", "--on-permission", "fail", "--timeout", "300", PROMPT],
        6 * 60_000
      )
      const reply = replyText(run.stdout)
      evidence.agentReply = run.code !== 0 || reply === null ? "failed" : reply === nonce ? "pass" : "mismatch"
      expect(evidence.agentReply === "pass", `agent reply: ${evidence.agentReply}${run.code !== 0 ? ` (acpmux exit ${run.code})` : ""}`)
    }
  } catch (e) {
    if (e instanceof Refused) throw e
    problems.unshift(e instanceof Failed ? e.message : `unexpected error (${e instanceof Error ? e.name : "unknown"})`)
  } finally {
    await cleanup()
  }

  // 5. Secret scan: the whole disposable home (as the user, one tar) and everything printed.
  const scanned = secrets.filter((v) => v.length >= 8)
  try {
    const archive = await userRun(["/usr/bin/tar", "-C", opts.home, "--format", "gnutar", "-cf", "-", "."], 5 * 60_000, true, true)
    // Sockets cannot be archived and hold nothing; any other complaint means the archive is not the whole home.
    const complaints = archive.stderr.split("\n").filter((l) => l.trim() && !/socket/i.test(l))
    if (archive.code !== 0 && complaints.length > 0) throw new Error("tar failed")
    let held = 0
    let cmj = 0
    for (const entry of tarEntries(archive.stdout)) {
      const text = `${entry.name}\n${entry.link}\n${entry.body}`
      cmj += count(text, "cmj_")
      for (const v of scanned) if (text.includes(v)) held += 1
    }
    evidence.secretScan.home = { held, cmj }
  } catch {
    problems.push("could not scan the whole disposable home")
  }
  const logText = [...transcript, ...childText].join("\n")
  evidence.secretScan.log = { held: scanned.filter((v) => logText.includes(v)).length, cmj: count(logText, "cmj_") }
  expect(evidence.secretScan.home.held === 0, "the home holds a value of this run's sign-in, token or API key")
  expect(evidence.secretScan.home.cmj === 0, "the home holds a join token")
  expect(evidence.secretScan.log.held === 0 && evidence.secretScan.log.cmj === 0, "the output holds a secret value or a join token")

  evidence.result = problems.length === 0 ? "pass" : "fail"
  evidence.reason = problems.length === 0 ? "vault set, joined over ssh, vault on the machine, the agent read it, cleaned up, no secrets found" : problems.join("; ")
  let text = JSON.stringify(evidence, null, 2)
  if (evidenceLeaks(text, secrets).length > 0) {
    text = JSON.stringify({ run: evidence.run, result: "fail", reason: "evidence redaction check failed" })
    evidence.result = "fail"
  }
  mkdirSync(dirname(opts.evidence), { recursive: true, mode: 0o700 })
  deps.writeFile(opts.evidence, `${text}\n`)
  say(`machine vault e2e: ${evidence.result}${evidence.result === "fail" ? ` (${evidence.reason})` : ""}`)
  if (evidence.result === "fail") {
    for (const line of childText.join("\n").split("\n").filter((l) => l.trim()).slice(-60)) say(`  child: ${line.slice(0, 300)}`)
  }
  return JSON.parse(text)
}

export function parseArgs(argv: string[]): Options {
  const value = (flag: string) => {
    const i = argv.indexOf(flag)
    return i >= 0 && i + 1 < argv.length ? argv[i + 1]! : ""
  }
  return {
    origin: value("--origin"),
    cmux: value("--cmux"),
    user: value("--user"),
    home: value("--home"),
    ssh: value("--ssh"),
    name: value("--name"),
    work: value("--work"),
    evidence: value("--evidence"),
    runId: value("--run"),
    sha: value("--sha")
  }
}

export function realDeps(): Deps {
  return {
    fetch: (url, init) => fetch(url, init),
    run: (argv, { env, stdin, timeoutMs, binary, signal }) =>
      new Promise((resolve) => {
        const child = spawn(argv[0]!, argv.slice(1), { env, cwd: "/", stdio: ["pipe", "pipe", "pipe"] })
        const out: Buffer[] = []
        const err: Buffer[] = []
        child.stdout.on("data", (b: Buffer) => out.push(b))
        child.stderr.on("data", (b: Buffer) => err.push(b))
        child.stdin.on("error", () => undefined)
        if (stdin !== undefined) child.stdin.write(stdin)
        child.stdin.end()
        let hard: ReturnType<typeof setTimeout> | undefined
        let grace: ReturnType<typeof setTimeout> | undefined
        // After SIGKILL the result comes at most KILL_GRACE_MS later, even if a descendant (ssh, say) still
        // holds the pipes open: they are let go and the run answers as killed.
        const kill = () => {
          child.kill("SIGKILL")
          grace ??= setTimeout(() => {
            child.stdout.destroy()
            child.stderr.destroy()
            done(null)
          }, KILL_GRACE_MS)
        }
        const timer = setTimeout(kill, timeoutMs)
        const stop = () => {
          child.kill("SIGTERM")
          hard = setTimeout(kill, 2_000)
        }
        if (signal?.aborted) stop()
        else signal?.addEventListener("abort", stop, { once: true })
        let settled = false
        const done = (code: number | null) => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          if (hard) clearTimeout(hard)
          if (grace) clearTimeout(grace)
          signal?.removeEventListener("abort", stop)
          resolve({ code, stdout: Buffer.concat(out).toString(binary ? "latin1" : "utf8"), stderr: Buffer.concat(err).toString("utf8") })
        }
        child.on("error", () => done(null))
        child.on("close", (code) => done(code))
      }),
    write: (line) => process.stdout.write(`${line}\n`),
    writeFile: (path, text) => writeFileSync(path, text, { mode: 0o600 }),
    removeFile: (path) => rmSync(path, { force: true }),
    now: () => Date.now(),
    random: () => Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("hex")
  }
}

if (import.meta.main) {
  const env = {
    CMUX_UITEST_STACK_EMAIL: process.env.CMUX_UITEST_STACK_EMAIL,
    CMUX_UITEST_STACK_PASSWORD: process.env.CMUX_UITEST_STACK_PASSWORD,
    CMUX_E2E_ANTHROPIC_API_KEY: process.env.CMUX_E2E_ANTHROPIC_API_KEY
  }
  for (const key of Object.keys(env)) delete process.env[key]
  const opts = parseArgs(process.argv.slice(2))
  const why = refusal(opts)
  if (why) {
    console.error(`machine-vault-e2e: refused: ${why}`)
    process.exit(2)
  }
  let cancelNow: (() => Promise<void>) | undefined
  let stopping = false
  const stop = () => {
    if (stopping) return
    stopping = true
    void cancelNow?.()
    setTimeout(() => process.exit(130), 20_000).unref()
  }
  for (const sig of ["SIGINT", "SIGTERM"] as const) process.on(sig, stop)
  runE2E(opts, env, realDeps(), (cancel) => (cancelNow = cancel)).then(
    (e) => process.exit(e.result === "pass" ? 0 : 1),
    (e) => {
      console.error(`machine-vault-e2e: refused: ${e instanceof Error ? e.message : "error"}`)
      process.exit(2)
    }
  )
}
