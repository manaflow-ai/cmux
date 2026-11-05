#!/usr/bin/env bun
/**
 * "Make this Mac a cmux machine", with the vault, end to end on the DEVELOPMENT platform, for
 * .github/workflows/machine-vault-e2e.yml.
 *
 *   bun scripts/cmux-next/machine-vault-e2e.ts --origin https://cmux-platform-development.debussy.workers.dev \
 *     --cmux PATH --user USER --home DIR --ssh PATH --name NAME --work DIR --evidence FILE --run ID --sha SHA
 *
 * The stack account comes only from this process's environment (CMUX_UITEST_STACK_EMAIL and
 * CMUX_UITEST_STACK_PASSWORD, the repo's dev stack pair), and the team's Claude subscription login from
 * CLAUDE_CODE_OAUTH_TOKEN. This process signs in, gets a cmux-api-development access token and writes it
 * to one 0600 file in `--work` (a 0700 directory in the runner's temp) for the CLI's
 * `--cloud-token-file`; the file is removed in `finally`. Every held value is masked (::add-mask::) the
 * moment it exists, children get a fixed environment, no argv carries a secret, and vault values reach
 * the CLI on stdin only. The Claude login never enters the vault (the vault refuses subscription logins,
 * and that refusal stays): it reaches only the disposable user's acpmux daemon, on ssh's stdin.
 *
 * Steps, each a real command a person runs:
 *   1. `cmux machine vault set MACHINE_VAULT_E2E --host postman-echo.com` (a random nonce on stdin):
 *      proxy delivery, so agents get the placeholder and only that host gets the value.
 *   2. `cmux machine add --vault --yes USER@localhost`: the token reaches the new user's shell on
 *      ssh's stdin, the served join.sh installs acpmux, Claude Code and Codex and pulls the vault.
 *   3. As that user: acpmux has `machine.vault.pull.v1` and `machine.vault.egress.v1` (else the channel
 *      is too old: refused), `acpmux machine vault status --json` lists MACHINE_VAULT_E2E in the keychain,
 *      delivered through the proxy.
 *   4. Claude Code signs in the normal way, from CLAUDE_CODE_OAUTH_TOKEN in its env: one ssh session to
 *      the user reads the token from its stdin into its shell's env (never argv, never a file), restarts
 *      the user's acpmux daemon with it (a daemon's own env reaches the agents it starts), drops it from
 *      the shell, and runs a Claude Code session through acpmux that prints `MACHINE_VAULT_E2E` (the
 *      placeholder `cmux-secret://MACHINE_VAULT_E2E`), sends it as a header to an echo API on the allowed
 *      host and to one on a host it does not allow, and replies with the three values and one sentence.
 *      The pass: the env holds the placeholder, the allowed host got this run's nonce, the other host got
 *      the placeholder, and a real model sentence; the reply text is the evidence's `agentReply`. Without the token this part
 *      is skipped and the evidence says so (the run fails: a skip is never a pass).
 *   5. Cleanup in `finally` and on SIGINT/SIGTERM, most important first: the user's processes (the
 *      daemon and agent that held the Claude login) are killed and confirmed gone, the machine revoke
 *      (the join's machine id directly, then confirmed on the list), the vault entries this run set, the
 *      install revoke, the sign-out, then the token file. A cleanup step it cannot confirm fails the
 *      run. After a cancel the whole cleanup ends by CANCEL_BUDGET_MS (GitHub's grace is SIGINT, then
 *      SIGTERM 7.5 s later, then SIGKILL): every request and command on what is left of it, less a
 *      killed child's grace; a step with no time left fails, and so does a pass still going then.
 *      Then a secret scan of the disposable home (skipped after a cancel) and the output: every held
 *      value, join tokens, and the Claude login on its own (a count only, which must be 0).
 * Exit 0 when the evidence says pass, 1 otherwise, 2 for a refused invocation.
 */
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { CANCEL_BUDGET_MS, byteForm, escapeData, evidenceLeaks, plainLine, redact, safeId, tarEntries } from "./machine-join-e2e.ts"

export { CANCEL_BUDGET_MS }
/** The process exits this long after a cancel, whatever is still running: before the runner's SIGKILL. */
export const CANCEL_EXIT_MS = 9_000

export const DEV_PLATFORM = "https://cmux-platform-development.debussy.workers.dev"
export const DEV_API = "https://cmux-api-development.debussy.workers.dev"
const STACK_API = "https://api.stack-auth.com/api/v1"
// The development Stack project cmux-api-development trusts, and its public client key (as machine-join-e2e.ts).
const DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
const DEV_STACK_CLIENT_KEY = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
const USER_AGENT = "cmux-machine-vault-e2e/1"
/** The vault var this run proves. Not CMUX_*: the vault refuses names cmux owns. */
export const NONCE_VAR = "MACHINE_VAULT_E2E"
/** The team's Claude subscription login: Claude Code reads it from its env. Never a vault entry. */
export const LOGIN_VAR = "CLAUDE_CODE_OAUTH_TOKEN"
export const VAULT_CAPABILITY = "machine.vault.pull.v1"
/** The proxy delivery's capability (placeholders and the machine's egress proxy). */
export const EGRESS_CAPABILITY = "machine.vault.egress.v1"
/** The placeholder an agent sees in place of the value. */
export const PLACEHOLDER = `cmux-secret://${NONCE_VAR}`
/** The one host the nonce is allowed to: an echo API that answers the request's headers as JSON. */
export const ALLOWED_HOST = "postman-echo.com"
/** An echo API on a host the nonce does not allow: it must get the placeholder. */
export const DENIED_HOST = "httpbin.org"
/** The header the agent sends the placeholder in (not an auth header: the evidence check refuses those). */
export const ECHO_HEADER = "x-cmux-e2e"
/** No single quote: it goes inside one in the ssh session's script. `$NAME` is the agent shell's own. */
export const PROMPT = `Run these three commands one at a time: \`printenv ${NONCE_VAR}\`, then \`curl -s https://${ALLOWED_HOST}/headers -H "${ECHO_HEADER}: $${NONCE_VAR}"\`, then \`curl -s https://${DENIED_HOST}/headers -H "${ECHO_HEADER}: $${NONCE_VAR}"\`. Then reply with exactly four lines and nothing else: env= followed by the output of the first; allowed= followed by the value of the ${ECHO_HEADER} header (any letter case) in the JSON the second printed; denied= followed by the value of that header in the JSON the third printed; then one short friendly sentence of your own.`
/** The reply as evidence: printable text, at most this long. */
export const REPLY_CAP = 400
/** A Claude login's shape (sk-ant-oat01-...), and every other Anthropic key's. */
export const ANTHROPIC_SHAPE = /sk-ant-/
/**
 * The ssh session that signs Claude Code in and runs the agent. Its stdin is the login, one line: read
 * into the shell's env, never argv or a file. The user's daemon restarts with it in its env (a daemon's
 * own env reaches every agent it starts, `cmux-tui/crates/acpmux/src/login_env.rs`), the shell drops it,
 * and the client runs one Claude Code session. Exit 90: no login on stdin; 91: no home; 92: the daemon
 * did not start again; 93: the join's daemon did not stop.
 */
/** The model stub's address on the runner (tests/fixtures/model-stub, started by the workflow): loopback only. */
export const STUB_URL = /^http:\/\/127\.0\.0\.1:\d{2,5}$/
/** The stub's script for this run: the three commands the prompt names, then the four-line reply from their output. */
export const STUB_SCRIPT = "tests/fixtures/model-stub/machine-vault-e2e.json"

/** With a model stub, Claude Code's own settings point it there before the daemon starts, so the login the run
 * passes goes nowhere but the stub. Without one, the script is the real-login one. */
export function agentScript(stubUrl = ""): string {
  if (stubUrl && !STUB_URL.test(stubUrl)) throw new Error("MODEL_STUB_URL must be http://127.0.0.1:PORT")
  const stub = stubUrl
    ? [
        `mkdir -p "$HOME/.claude" || exit 94`,
        `python3 -c 'import json,os,sys; p=os.path.expanduser("~/.claude/settings.json"); c=json.load(open(p)) if os.path.exists(p) else {}; c.setdefault("env", {})["ANTHROPIC_BASE_URL"]=sys.argv[1]; json.dump(c, open(p, "w"))' ${stubUrl} || exit 94`
      ]
    : []
  // After the PATH export and the cd (the first five lines), before the daemon restarts. Exit 94: the stub settings failed.
  return [...AGENT_LOGIN_LINES.slice(0, 5), ...stub, ...AGENT_LOGIN_LINES.slice(5)].join("\n")
}

const AGENT_LOGIN_LINES = [
  `IFS= read -r ${LOGIN_VAR} || exit 90`,
  `[ -n "$${LOGIN_VAR}" ] || exit 90`,
  `export ${LOGIN_VAR}`,
  `export PATH="$HOME/.local/bin:$HOME/.cmux/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=C.UTF-8`,
  "cd || exit 91",
  "acpmux daemon shutdown >/dev/null 2>&1",
  // The join's daemon (no login in its env) must be gone, or the start below would leave it serving.
  `case "$(acpmux daemon status 2>&1)" in "daemon not running"*) ;; *) exit 93 ;; esac`,
  "acpmux daemon start >/dev/null 2>&1 || exit 92",
  `unset ${LOGIN_VAR}`,
  `exec acpmux --json run -m claude --policy approve-all --on-permission fail --timeout 300 '${PROMPT}'`
]
export const AGENT_SCRIPT = agentScript()
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
  /** Reads a file the run owns (the model stub's log); "" when it is missing. */
  readFile?(path: string): string
  /** Writes `text` to a new file with mode 0600. */
  writeFile(path: string, text: string): void
  removeFile(path: string): void
  now(): number
  /** Resolves after `ms`, or as soon as `signal` aborts (its timer is cleared then). */
  sleep(ms: number, signal: AbortSignal): Promise<void>
  random(): string
}

export interface Evidence {
  run: { id: string; sha: string }
  hubOrigin: string
  name: string
  user: string
  nonce: string | null
  vaultSet: { nonce: boolean }
  join: { exit: number | null; joinTokenId: string | null; machineId: string | null }
  acpmuxCapability: boolean | null
  vaultStatus: { env: string[]; proxied: string[]; secretStore: string | null; joined: boolean | null; lastResult: string | null } | null
  /** The Claude Code session's reply text (the nonce line and one sentence), or null with no reply. */
  agentReply: string | null
  agentResult: "pass" | "mismatch" | "failed" | "skipped (no CLAUDE_CODE_OAUTH_TOKEN)" | null
  /** stub: the model was tests/fixtures/model-stub on the runner and the login a made-up one; real: the team's
   * subscription (the canary). `requests` and `loginMatched` read the stub's log: every model request carried the
   * login the run passed (SHA-256 match). */
  model: { mode: "stub" | "real"; requests: number | null; loginMatched: boolean | null }
  /** How the subscription login was used: on ssh's stdin into the restarted daemon's env. */
  claudeLogin: { delivery: "ssh-stdin"; daemonRestarted: boolean | null }
  /** Hits, counts only. `login` is the Claude login's value; null where the scan did not run. */
  secretScan: { home: { held: number | null; cmj: number | null; login: number | null; files?: string[] }; log: { held: number; cmj: number; login: number | null } }
  cleanup: {
    /** True when no acpmux or claude process of the user is left (they held the login); null when unchecked. */
    loginHoldersStopped: boolean | null
    machinesRevoked: number
    /** True when the list shows none of this run's machines live; null when no join started. */
    machinesConfirmed: boolean | null
    vaultRemoved: string[]
    installRevoked: boolean | null
    signedOut: boolean | null
    tokenFileRemoved: boolean
    /** Milliseconds from the cancel to the end of cleanup; null without a cancel. */
    cancelCleanupMs: number | null
  }
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

/** Join tokens in `text`, by their shape (cmj_ and at least 16 token characters; the mint's own rule). */
export const tokenCount = (text: string) => (text.match(/cmj_[A-Za-z0-9_-]{16,4096}/g) ?? []).length
/** A program file (Mach-O, fat Mach-O, ELF, or a #! script is not one): its constants are not secrets. */
export const isProgram = (body: string) =>
  ["\xcf\xfa\xed\xfe", "\xce\xfa\xed\xfe", "\xca\xfe\xba\xbe", "\xbe\xba\xfe\xca", "\x7fELF"].some((magic) => body.startsWith(magic))

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

/** The model stub's log rows for Claude Code's turns (streamed POST /v1/messages). */
export function stubTurns(log: string): { cred_sha256: string }[] {
  return log
    .split("\n")
    .filter(Boolean)
    .map((l) => {
      try {
        return JSON.parse(l)
      } catch {
        return null
      }
    })
    .filter((r) => r && r.protocol === "anthropic" && r.path === "/v1/messages" && r.method === "POST")
}

/** The reply text of `acpmux --json run`: its `reply`, trimmed. */
export function replyText(stdout: string): string | null {
  const reply = lastJson(stdout)?.reply
  return typeof reply === "string" ? reply.trim() : null
}

/** The reply as evidence: printable characters and newlines, at most REPLY_CAP. */
export const replyEvidence = (reply: string) =>
  reply.replace(/[^\x20-\x7e\n]/g, "").slice(0, REPLY_CAP)

/** A pass (backticks or quotes around a line are fine): `env=` the placeholder (the agent never saw the
 * value), `allowed=` this run's nonce (the proxy put it in for the allowed host), `denied=` the
 * placeholder (the other host never got the value), and another line of real words, the model's own. */
export function replyPasses(reply: string, nonce: string): boolean {
  const lines = reply.split("\n").map((l) => l.trim().replace(/^[`'"*]+|[`'"*]+$/g, "").trim()).filter(Boolean)
  const want = [`env=${PLACEHOLDER}`, `allowed=${nonce}`, `denied=${PLACEHOLDER}`]
  const at = want.map((w) => lines.findIndex((l) => l === w))
  if (at.some((i) => i < 0)) return false
  return lines.some((l, i) => !at.includes(i) && /[A-Za-z]{2,}(?:\W+[A-Za-z]{2,}){2,}/.test(l))
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
    vaultSet: { nonce: false },
    join: { exit: null, joinTokenId: null, machineId: null },
    acpmuxCapability: null,
    vaultStatus: null,
    agentReply: null,
    agentResult: null,
    model: { mode: env.MODEL_STUB_URL ? "stub" : "real", requests: null, loginMatched: null },
    claudeLogin: { delivery: "ssh-stdin", daemonRestarted: null },
    secretScan: { home: { held: null, cmj: null, login: null }, log: { held: 0, cmj: 0, login: null } },
    cleanup: { loginHoldersStopped: null, machinesRevoked: 0, machinesConfirmed: null, vaultRemoved: [], installRevoked: null, signedOut: null, tokenFileRemoved: false, cancelCleanupMs: null },
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
  // A cancel sets one absolute deadline, CANCEL_BUDGET_MS after it, aborts every main-flow request and
  // stops every main-flow child. Every later request and command (cleanup's own) ends by the deadline:
  // `budget(cap, grace)` is `cap` before a cancel; after it, what is left of the deadline less `grace`
  // (at most `cap`), and a step with no time left is not started: it fails instead. A command's grace is
  // KILL_GRACE_MS, the time its result may take after the SIGKILL its timeout sends.
  let cancelled = false
  let cancelAt = 0
  let cancelBy = Infinity
  const stopRequests = new AbortController()
  const left = () => cancelBy - deps.now()
  const budget = (cap: number, grace = 0) => {
    if (!cancelled) return cap
    const ms = Math.min(cap, left() - grace)
    if (ms <= 0) throw new Failed("cleanup ran out of the cancel deadline")
    return ms
  }
  // Resolves on the cancel.
  let wake: () => void = () => undefined
  const woken = new Promise<void>((resolve) => (wake = resolve))
  /** True when `work` settles within `ms`; the timer is dropped either way. */
  const within = async (work: Promise<unknown>, ms: number) => {
    const timer = new AbortController()
    try {
      return await Promise.race([work.then(() => true, () => true), deps.sleep(ms, timer.signal).then(() => false)])
    } finally {
      timer.abort()
    }
  }
  /** Waits for what the main flow has in flight. After a cancel, at most 2.5 s of the deadline: its
   * requests were aborted and its children stopped, so they answer in that time; a write that still
   * lands later is caught by the vault list after the removal. */
  const settlePending = async () => {
    while (pending.size > 0) {
      if (!cancelled) await Promise.allSettled([...pending])
      else if (!(await within(Promise.allSettled([...pending]), Math.max(0, Math.min(2_500, left() - 4_000))))) {
        say("cleanup: a step still in flight after the cancel; cleaning up without it")
        return
      }
    }
  }
  // Cleanup's own calls pass its pass's signal (`own`): they are neither tracked nor refused, end by the
  // cancel's deadline, and stop when a cancel interrupts the pass they belong to.
  const ownCheck = (own: AbortSignal) => {
    if (own.aborted) throw new Failed("cleanup pass interrupted by the cancel")
  }
  const cli = async (args: string[], stdin?: string, timeoutMs = 60_000, own?: AbortSignal) => {
    if (own) ownCheck(own)
    else live()
    const work = deps.run([opts.cmux, ...args, "--cloud-token-file", tokenFile], {
      env: cliEnv,
      timeoutMs: own ? budget(timeoutMs, KILL_GRACE_MS) : timeoutMs,
      ...(stdin === undefined ? {} : { stdin }),
      signal: own ?? stopChildren.signal
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
  const userRun = async (args: string[], timeoutMs = 60_000, binary = false, own?: AbortSignal) => {
    if (own) ownCheck(own)
    else live()
    const work = deps.run(asUser(args), { env: { PATH: CHILD_PATH }, timeoutMs: own ? budget(timeoutMs, KILL_GRACE_MS) : timeoutMs, binary, signal: own ?? stopChildren.signal })
    const r = await (own ? work : track(work))
    if (!binary) childText.push(r.stdout, r.stderr)
    return r
  }
  const acpmux = `${opts.home}/.local/bin/acpmux`
  /** One ssh session to the user (the workflow's key wrapper), `script` its only argument, `stdin` its input. */
  const sshUser = async (script: string, stdin: string, timeoutMs: number) => {
    live()
    const r = await track(deps.run([opts.ssh, "--", `${opts.user}@localhost`, script], { env: { PATH: CHILD_PATH, LANG: "C.UTF-8" }, stdin, timeoutMs, signal: stopChildren.signal }))
    childText.push(r.stdout, r.stderr)
    return r
  }

  const call = async (url: string, init: { method: string; headers?: Record<string, string>; body?: unknown }, own?: AbortSignal) => {
    if (own) {
      ownCheck(own)
      // After a cancel each request gets at most 3 s, and never past the deadline.
      return request(url, init, AbortSignal.any([AbortSignal.timeout(budget(cancelled ? 3_000 : 20_000)), own]))
    }
    live()
    return track(request(url, init, AbortSignal.any([AbortSignal.timeout(20_000), stopRequests.signal])))
  }
  const request = async (url: string, init: { method: string; headers?: Record<string, string>; body?: unknown }, signal: AbortSignal) => {
    const res = await deps.fetch(url, {
      method: init.method,
      redirect: "error",
      signal,
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
  // The ssh session that hands the daemon the Claude login started: cleanup confirms its holders are gone.
  let agentStarted = false
  // A name goes here before its write starts: cleanup removes it whether or not the write finished.
  const vaultAttempted: string[] = []

  const op = async (name: string, params: unknown, own?: AbortSignal) => {
    const r = await call(`${DEV_API}/v1/ops`, {
      method: "POST",
      headers: { authorization: `Bearer ${stack!.access}` },
      body: { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" }
    }, own)
    if (r.status !== 200 || r.json?.ok !== true) throw refusedBy(name, r)
    return r.json.value
  }
  const accessToken = async (own?: AbortSignal) => {
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
  const platform = async (method: string, path: string, own?: AbortSignal) =>
    call(`${opts.origin}${path}`, { method, headers: { authorization: `Bearer ${await accessToken(own)}` } }, own)
  /** The token file, fresh: the CLI reads it on each command. */
  const writeToken = async (own?: AbortSignal) => {
    const token = await accessToken(own)
    // An interrupted cleanup pass never writes it again: the pass that replaced it may have removed it.
    if (own) ownCheck(own)
    deps.writeFile(tokenFile, `${token}\n`)
    tokenWritten = true
    evidence.cleanup.tokenFileRemoved = false
  }

  /** Revokes this run's machine: the id the join printed directly, then whatever the list still shows
   * live under this run's name or join token, until the list shows none (two looks at most; else the
   * cleanup is unconfirmed and fails the run). Without a cancel, it also revokes this account's earlier
   * CI vault machines (ci-vault-<digits>) still live 30 minutes after they were made; a failure there
   * fails the run too. */
  const revokeMachines = async (own: AbortSignal, found: string[]) => {
    const direct = evidence.join.machineId
    const revoke = async (id: string, note: string) => {
      const done = await platform("POST", `/v1/machines/credentials/${encodeURIComponent(id)}/revoke`, own)
      if (done.status >= 200 && done.status < 300) {
        evidence.cleanup.machinesRevoked += 1
        say(`revoked machine ${id}${note}`)
        return undefined
      }
      return `revoke ${id}${note}: HTTP ${done.status}`
    }
    // The join named its machine: revoke it first, before any list. A failure here shows on the list below.
    if (direct) await revoke(direct, "")
    const stale: string[] = []
    for (let look = 0; ; look++) {
      const r = await platform("GET", "/v1/machines/credentials", own)
      if (r.status !== 200 || !Array.isArray(r.json?.machines)) throw new Failed(`machine revoke unconfirmed: list HTTP ${r.status}`)
      const live: string[] = []
      for (const m of r.json.machines as any[]) {
        const id = safeId(m?.machineId)
        if (!id || m?.revoked !== false) continue
        const label = String(m?.label ?? "")
        const made = Date.parse(String(m?.createdAt ?? ""))
        const ours = id === direct || label === opts.name || (evidence.join.joinTokenId !== null && m?.joinTokenId === evidence.join.joinTokenId)
        if (ours) live.push(id)
        else if (look === 0 && m?.mintedBy === user && /^ci-vault-\d+(?:-\d+)?$/.test(label) && Number.isFinite(made) && deps.now() - made > 30 * 60_000) stale.push(id)
      }
      if (live.length === 0) break
      if (look >= 1) throw new Failed(`machine ${live.join(", ")} is still live after cleanup`)
      for (const id of live) await revoke(id, "")
    }
    evidence.cleanup.machinesConfirmed = true
    // Earlier runs' leftovers are not this run's: never on a cancel's deadline.
    if (!cancelled) {
      for (const id of stale) {
        const failed = await revoke(id, " (left by an earlier run)")
        if (failed) found.push(failed)
      }
    }
  }

  /** One cleanup pass, most important first: the machine, the vault, the install, the
   * sign-out. Every step is required: what it cannot confirm goes in `found` and fails the run. A pass
   * can run again (a cancel interrupts a running one and starts a fresh one on its deadline). */
  const cleanupPass = async (own: AbortSignal, found: string[]) => {
    const fail = (e: unknown, what: string) => found.push(e instanceof Failed ? e.message : what)
    // The user's processes go, alongside the rest.
    const killing = (async () => deps.run(["sudo", "-n", "-u", opts.user, "--", "/bin/kill", "-KILL", "-1"], { env: { PATH: CHILD_PATH }, timeoutMs: budget(5_000, KILL_GRACE_MS), signal: own }))()
      .catch(() => undefined)
    // Wait for what the main flow had in flight, so nothing it started lands after this looks. A cancel
    // after a vault write or the registration started but before it answered left `stack` and `install`
    // set by now (the tracked promise settled first), so they are undone below.
    await settlePending()
    if (stack && install) {
      if (addStarted) {
        evidence.cleanup.machinesConfirmed = false
        await revokeMachines(own, found).catch((e) => fail(e, "machine revoke unconfirmed"))
      }
      if (vaultAttempted.length > 0) {
        try {
          await writeToken(own)
          for (const name of vaultAttempted) await cli(["machine", "vault", "rm", name], undefined, 60_000, own)
          // The proof is the list, not rm's exit: a write that never landed has nothing to remove.
          const after = await cli(["--json", "machine", "vault", "ls"], undefined, 60_000, own)
          const rows = lastJson(after.stdout)?.entries
          if (after.code !== 0 || !Array.isArray(rows)) throw new Failed("vault ls after cleanup failed")
          const still = new Set<string>(rows.map((e: any) => String(e?.name ?? "")))
          evidence.cleanup.vaultRemoved = vaultAttempted.filter((n) => !still.has(n))
          for (const name of vaultAttempted) if (still.has(name)) found.push(`vault entry ${name} is still in the vault after cleanup`)
        } catch (e) {
          fail(e, "vault cleanup failed")
        }
      }
    }
    if (install && stack && evidence.cleanup.installRevoked !== true) {
      evidence.cleanup.installRevoked = await op("install.revoke", { install }, own).then(() => true, () => false)
      if (!evidence.cleanup.installRevoked) found.push("could not revoke the run's cmux install")
    }
    if (stack && evidence.cleanup.signedOut !== true) {
      const out = await call(`${STACK_API}/auth/sessions/current`, {
        method: "DELETE",
        headers: { ...stackHeaders(), "x-stack-access-token": stack.access, "x-stack-refresh-token": stack.refresh }
      }, own).catch(() => undefined)
      evidence.cleanup.signedOut = out !== undefined && out.status >= 200 && out.status < 300
      if (!evidence.cleanup.signedOut) found.push("could not sign out the run's Stack session")
    }
    await killing
    // The daemon and the agent held the Claude login in their env: none of them may be left.
    if (agentStarted && !cancelled) {
      evidence.cleanup.loginHoldersStopped = false
      for (let look = 0; look < 5; look++) {
        const left = await deps.run(["/usr/bin/pgrep", "-U", opts.user, "-f", "acpmux|claude"], { env: { PATH: CHILD_PATH }, timeoutMs: 10_000, signal: own })
        if (left.code === 1) {
          evidence.cleanup.loginHoldersStopped = true
          break
        }
        await deps.run(["sudo", "-n", "-u", opts.user, "--", "/bin/kill", "-KILL", "-1"], { env: { PATH: CHILD_PATH }, timeoutMs: 5_000, signal: own }).catch(() => undefined)
        await deps.sleep(1_000, own)
      }
      if (!evidence.cleanup.loginHoldersStopped) found.push("a process that held the Claude login is still running after cleanup")
    }
  }

  // The pass running now, its stop and its findings; only the last pass's findings count.
  const removeToken = (found: string[]) => {
    try {
      deps.removeFile(tokenFile)
      evidence.cleanup.tokenFileRemoved = true
    } catch {
      evidence.cleanup.tokenFileRemoved = false
      found.push("could not remove the token file")
    }
  }
  let current: Promise<void> = Promise.resolve()
  let passStop = new AbortController()
  let passFound: string[] = []
  const startPass = () => {
    passStop = new AbortController()
    passFound = []
    return (current = cleanupPass(passStop.signal, passFound))
  }
  let cleaning: Promise<void> | undefined
  const cleanup = () =>
    (cleaning ??= (async () => {
      stopChildren.abort()
      startPass()
      // A cancel during a pass replaces `current` with a fresh pass: wait until none replaced the one awaited.
      // After a cancel, the wait ends at the deadline whatever is still running: that pass is stopped and
      // the run fails.
      let awaited: Promise<void>
      let late = false
      do {
        awaited = current
        if (!cancelled) await Promise.race([awaited.catch(() => undefined), woken])
        else if (!(await within(awaited, Math.max(0, left())))) {
          passStop.abort()
          late = true
          break
        }
      } while (awaited !== current)
      const found = [...passFound]
      if (late) found.push("cleanup did not finish by the cancel deadline")
      // The token file goes once every pass is over or stopped (a stopped pass writes it no more), so no
      // pass can write it after its removal.
      if (tokenWritten) removeToken(found)
      problems.push(...found)
      if (cancelled) evidence.cleanup.cancelCleanupMs = deps.now() - cancelAt
    })())
  /** A signal: one deadline, CANCEL_BUDGET_MS from now. Stop the main flow; a cleanup pass already running
   * (on its long timeouts) is interrupted and a fresh one runs on the deadline. */
  const cancel = () => {
    if (!cancelled) {
      cancelled = true
      cancelAt = deps.now()
      cancelBy = cancelAt + CANCEL_BUDGET_MS
      problems.push("cancelled")
      stopRequests.abort()
      stopChildren.abort()
      if (cleaning) {
        const old = current
        passStop.abort()
        current = within(old, Math.max(0, Math.min(1_000, left()))).then(() => startPass())
      }
      wake()
    }
    return cleanup()
  }
  onCancel?.(cancel)
  const live = () => {
    if (cleaning) throw new Failed("cancelled before the next step")
  }

  // The Claude login: masked as soon as it is read, given only to the ssh session's stdin.
  let login = ""
  const stubUrl = env.MODEL_STUB_URL ?? ""
  try {
    const why = refusal(opts)
    if (why) throw new Refused(why)
    const email = env.CMUX_UITEST_STACK_EMAIL ?? ""
    const password = env.CMUX_UITEST_STACK_PASSWORD ?? ""
    // With the model stub the login is made up here: the stub checks it arrived, and no real one exists.
    login = stubUrl ? `sk-ant-oat01-vaultstub-${deps.random()}${deps.random()}` : env.CLAUDE_CODE_OAUTH_TOKEN ?? ""
    // A real login in the env of a stub run is never used, but is still masked and scanned for.
    if (stubUrl && env.CLAUDE_CODE_OAUTH_TOKEN) hold(env.CLAUDE_CODE_OAUTH_TOKEN)
    if (!email || !password) throw new Refused("CMUX_UITEST_STACK_EMAIL and CMUX_UITEST_STACK_PASSWORD must be set")
    hold(email)
    hold(password)
    hold(login)

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

    // 1. The vault: the nonce (never over an entry this run did not make). Never the Claude login.
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
    const setNonce = await cli(["machine", "vault", "set", NONCE_VAR, "--host", ALLOWED_HOST], `${nonce}\n`)
    if (setNonce.code !== 0) throw new Failed(`vault set ${NONCE_VAR}: exit ${setNonce.code}`)
    evidence.vaultSet.nonce = true
    say(`vault: set ${NONCE_VAR} (proxy, ${ALLOWED_HOST} only)`)

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
    const capLines = caps.code === 0 ? caps.stdout.split("\n").map((l) => l.trim()) : []
    evidence.acpmuxCapability = capLines.includes(VAULT_CAPABILITY) && capLines.includes(EGRESS_CAPABILITY)
    if (!evidence.acpmuxCapability) throw new Failed(`the installed acpmux lacks ${VAULT_CAPABILITY} or ${EGRESS_CAPABILITY}: its channel predates the vault's egress proxy`)
    const status = await userRun([acpmux, "--json", "machine", "vault", "status"])
    const s = lastJson(status.stdout)
    evidence.vaultStatus = {
      env: Array.isArray(s?.env) ? (s.env as any[]).map((e) => String(e?.name ?? "")).filter((n) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(n)) : [],
      proxied: Array.isArray(s?.env) ? (s.env as any[]).filter((e) => e?.delivery === "proxy").map((e) => String(e?.name ?? "")).filter((n) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(n)) : [],
      secretStore: typeof s?.secretStore === "string" ? s.secretStore.replace(/[^a-z-]/g, "") : null,
      joined: typeof s?.joined === "boolean" ? s.joined : null,
      lastResult: typeof s?.lastResult === "string" ? s.lastResult.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 64) : null
    }
    expect(status.code === 0, `vault status: exit ${status.code}`)
    expect(evidence.vaultStatus.joined === true, "vault status: not joined")
    expect(evidence.vaultStatus.secretStore === "keychain", "vault status: the secret store is not the keychain")
    expect(evidence.vaultStatus.env.includes(NONCE_VAR), `vault status: ${NONCE_VAR} is not on the machine`)
    expect(evidence.vaultStatus.proxied.includes(NONCE_VAR), `vault status: ${NONCE_VAR} is not delivered through the proxy`)

    // 4. A Claude Code agent through acpmux, signed in with the team's subscription, reads it.
    live()
    if (!login) {
      evidence.agentResult = "skipped (no CLAUDE_CODE_OAUTH_TOKEN)"
      deps.write("::notice::the agent part was skipped: the CLAUDE_CODE_OAUTH_TOKEN secret is empty, so no Claude Code session ran")
      problems.push("agent part skipped (no CLAUDE_CODE_OAUTH_TOKEN)")
    } else {
      agentStarted = true
      // The login is this ssh session's stdin, one line; the script is the only argument.
      const run = await sshUser(agentScript(stubUrl), `${login}\n`, 6 * 60_000)
      evidence.claudeLogin.daemonRestarted = run.code !== null && ![90, 91, 92, 93, 94].includes(run.code)
      const reply = replyText(run.stdout)
      evidence.agentReply = reply === null ? null : replyEvidence(reply)
      evidence.agentResult = run.code !== 0 || reply === null ? "failed" : replyPasses(reply, nonce) ? "pass" : "mismatch"
      expect(evidence.agentResult === "pass", `agent reply: ${evidence.agentResult}${run.code !== 0 ? ` (exit ${run.code})` : ""}`)
      if (stubUrl) {
        const turns = stubTurns(env.MODEL_STUB_LOG ? (deps.readFile?.(env.MODEL_STUB_LOG) ?? "") : "")
        const want = createHash("sha256").update(login).digest("hex")
        evidence.model.requests = turns.length
        evidence.model.loginMatched = turns.length > 0 && turns.every((t) => t.cred_sha256 === want)
        expect(turns.length > 0, "model stub: Claude Code sent it no /v1/messages request")
        expect(evidence.model.loginMatched === true, "model stub: a model request did not carry the login the run passed")
      }
    }
  } catch (e) {
    if (e instanceof Refused) throw e
    problems.unshift(e instanceof Failed ? e.message : `unexpected error (${e instanceof Error ? e.name : "unknown"})`)
  } finally {
    await cleanup()
  }

  // 5. Secret scan: the whole disposable home (as the user, one tar) and everything printed.
  // After a cancel the home scan is skipped (the run already fails; the workflow deletes the home), so
  // the evidence is written before the runner's SIGKILL.
  const scanned = secrets.filter((v) => v.length >= 8)
  const scanOwn = new AbortController().signal
  try {
    if (cancelled) throw new Error("cancelled")
    // The user's processes are gone: their sockets hold nothing and tar cannot archive them, so they go
    // first. Then the archive must be whole: a nonzero exit fails, and so does any complaint.
    const sockets = await userRun(["/usr/bin/find", opts.home, "-type", "s", "-delete"], 60_000, false, scanOwn)
    if (sockets.code !== 0) throw new Error("socket cleanup failed")
    const archive = await userRun(["/usr/bin/tar", "-C", opts.home, "--format", "gnutar", "-cf", "-", "."], 5 * 60_000, true, scanOwn)
    if (archive.code !== 0) throw new Error("tar exited nonzero")
    if (archive.stderr.trim() !== "") throw new Error("tar complained")
    let held = 0
    let cmj = 0
    let loginHits = 0
    // Where a hit is, as a path in the home (never the value), so a failure names the file to fix.
    const files = new Set<string>()
    for (const entry of tarEntries(archive.stdout)) {
      const text = `${entry.name}\n${entry.link}\n${entry.body}`
      // A join token's shape, outside program files: an installed binary (acpmux, Claude Code, Codex)
      // carries the bare prefix as a constant, never a token. Held values are matched everywhere.
      if (!isProgram(entry.body)) cmj += tokenCount(text)
      let hit = false
      for (const v of scanned) if (text.includes(v)) { held += 1; hit = true }
      if (login && text.includes(login)) { loginHits += 1; hit = true }
      if (hit) files.add(plainLine(redact(entry.name, secrets)).slice(0, 200))
    }
    evidence.secretScan.home = { held, cmj, login: login ? loginHits : null, files: [...files].sort().slice(0, 20) }
  } catch {
    if (!cancelled) problems.push("could not scan the whole disposable home")
  }
  const logText = [...transcript, ...childText].join("\n")
  evidence.secretScan.log = {
    held: scanned.filter((v) => logText.includes(v)).length,
    cmj: tokenCount(logText),
    login: login ? logText.split(login).length - 1 : null
  }
  expect(evidence.secretScan.home.held === 0, "the home holds a value of this run's sign-in, token or Claude login")
  expect(!evidence.secretScan.home.login, "the home holds the Claude login")
  expect(!evidence.secretScan.log.login, "the output holds the Claude login")
  expect(evidence.secretScan.home.cmj === 0, "the home holds a join token")
  expect(evidence.secretScan.log.held === 0 && evidence.secretScan.log.cmj === 0, "the output holds a secret value or a join token")

  evidence.result = problems.length === 0 ? "pass" : "fail"
  evidence.reason = problems.length === 0 ? `vault set, joined over ssh, vault on the machine, the agent ${stubUrl ? "on the model stub (its login reached every model request)" : "signed in with the subscription"} saw only the placeholder, the allowed host got the value and the other host the placeholder, cleaned up, no secrets found` : problems.join("; ")
  let text = JSON.stringify(evidence, null, 2)
  if (evidenceLeaks(text, secrets).length > 0 || ANTHROPIC_SHAPE.test(text)) {
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
        // Its own process group, so a stop reaches every descendant (ssh under the CLI), not only the child.
        const child = spawn(argv[0]!, argv.slice(1), { env, cwd: "/", stdio: ["pipe", "pipe", "pipe"], detached: true })
        const signalGroup = (sig: NodeJS.Signals) => {
          try {
            if (child.pid) process.kill(-child.pid, sig)
          } catch {
            child.kill(sig)
          }
        }
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
          signalGroup("SIGKILL")
          grace ??= setTimeout(() => {
            child.stdout.destroy()
            child.stderr.destroy()
            done(null)
          }, KILL_GRACE_MS)
        }
        const timer = setTimeout(kill, timeoutMs)
        const stop = () => {
          signalGroup("SIGTERM")
          hard = setTimeout(kill, 1_000)
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
    readFile: (path) => (existsSync(path) ? readFileSync(path, "utf8") : ""),
    now: () => Date.now(),
    sleep: (ms, signal) =>
      new Promise((resolve) => {
        const timer = setTimeout(resolve, ms)
        signal.addEventListener("abort", () => {
          clearTimeout(timer)
          resolve()
        }, { once: true })
      }),
    random: () => Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("hex")
  }
}

if (import.meta.main) {
  const env = {
    CMUX_UITEST_STACK_EMAIL: process.env.CMUX_UITEST_STACK_EMAIL,
    CMUX_UITEST_STACK_PASSWORD: process.env.CMUX_UITEST_STACK_PASSWORD,
    CLAUDE_CODE_OAUTH_TOKEN: process.env.CLAUDE_CODE_OAUTH_TOKEN,
    MODEL_STUB_URL: process.env.MODEL_STUB_URL,
    MODEL_STUB_LOG: process.env.MODEL_STUB_LOG
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
    setTimeout(() => process.exit(130), CANCEL_EXIT_MS).unref()
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
