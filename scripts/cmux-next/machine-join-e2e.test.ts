import { describe, expect, test } from "bun:test"
import {
  CANCEL_BUDGET_MS,
  CHILD_PATH,
  KILL_GRACE_MS,
  REVOKE_RESERVE_MS,
  DEV_API,
  DEV_PLATFORM,
  type ChildResult,
  type Deps,
  type Options,
  evidenceLeaks,
  redact,
  byteForm,
  heartbeatMs,
  realDeps,
  refusal,
  runE2E,
  safeId,
  tarEntries
} from "./machine-join-e2e.ts"

// Fake values shaped like the real ones; none is a real credential.
const EMAIL = "ci-account@example.invalid"
const PASSWORD = "fake-password-value"
const STACK_ACCESS = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJzdGFjay11c2VyIn0.c3RhY2tzaWduYXR1cmU"
const STACK_REFRESH = "fake-stack-refresh-token-value"
const ACCESS = "eyJhbGciOiJFUzI1NiIsImtpZCI6ImsxIn0.eyJzdWIiOiJ1c2VyXzEiLCJ0ZWFtIjoidGVhbV8xIn0.YWNjZXNzc2lnbmF0dXJl"
const TOKEN = "cmj_FAKEjoinTOKENvalue_0123456789abcdef"
const CREDENTIAL = "cmm_FAKEmachineCREDENTIALvalue_0123456789abcdefghijk"
const HOME = "/tmp/machine-join-e2e.test/home"
const CRED_PATH = `${HOME}/.acpmux/machine-credential.json`
const SECRETS = [EMAIL, PASSWORD, STACK_ACCESS, STACK_REFRESH, ACCESS, TOKEN, CREDENTIAL]

const opts: Options = {
  origin: DEV_PLATFORM,
  acpmux: "/tmp/machine-join-e2e.test/bin/acpmux",
  user: "cmuxjoin-1-1",
  home: HOME,
  name: "ci-join-1",
  evidence: "/tmp/machine-join-e2e.test/evidence.json",
  runId: "1",
  sha: "a".repeat(40)
}
const env = { CMUX_UITEST_STACK_EMAIL: EMAIL, CMUX_UITEST_STACK_PASSWORD: PASSWORD }

interface Knobs {
  mintStatus?: number
  joinExit?: number
  heartbeat?: boolean
  revokeStatus?: number
  joinStderr?: string
  homeFiles?: Record<string, string>
  /** The mint answers without a joinTokenId. */
  noJoinTokenId?: boolean
  /** The join redeems (the platform lists the machine) but then exits with this code. */
  redeemThenExit?: number
  /** List reads before a redeemed machine shows up. */
  listVisibleAfter?: number
  /** The credential file's text, instead of a valid record. */
  credentialFile?: string
  /** Runs while the join child is in flight (a cancel arriving then). */
  duringJoin?: () => void
  /** The join child stays in flight until the user's processes are killed; it has redeemed by then. */
  holdJoin?: boolean
  /** Machines other runs left in the list. */
  others?: Array<Record<string, unknown>>
  /** Reading a home file other than the credential file fails. */
  catFails?: boolean
  /** Each list read takes this long (fake time). */
  listDelayMs?: number
  /** The first machine revoke hangs until its request is aborted; `onRevoke` runs when it starts. */
  hangFirstRevoke?: boolean
  onRevoke?: () => void
  /** Status fails once the daemon runs, so the run fails with its daemon up. */
  statusFailsWithDaemon?: boolean
  /** The daemon never exits on its own. */
  daemonHangs?: boolean
  /** A sleep of exactly this long never ends; `onHang` runs when it starts. */
  hangSleepMs?: number
  onHang?: () => void
  /** What the join prints as its machineId. */
  joinMachineId?: string
  /** What status reports as the credential path. */
  statusCredentialPath?: string
  /** What `stat -c %F|%U|%h|%a` says of the credential file. */
  credentialStat?: string
  /** What stat says of the credential file before the daemon starts, when it differs from after. */
  credentialStatBeforeDaemon?: string
  /** install.register answers this long after it arrives, and honours the request's abort meanwhile. */
  registerDelayMs?: number
  /** What status shows as consent.screen (default "none"). */
  consentScreen?: unknown
  /** What `stat -c %F|%U|%h|%a` says of the state directory. */
  stateDirStat?: string
  /** Each kill command takes this long to return. */
  killDelayMs?: number
  /** A held join ends this long after it is told to stop (a kill, or its launcher's signal). */
  joinLingersMs?: number
  /** A held join ignores the user's kills (a launcher not yet that user); only its own signal stops it. */
  launcherOnly?: boolean
  /** Runs as each cmux-api op arrives, before its answer. */
  onOp?: (op: string) => void
  /** How status shows a heartbeat at `ms` (default: the ms as a string, as acpmux does). */
  heartbeatValue?: (ms: number) => unknown
  /** How the platform's list shows a heartbeat at `ms` (default: RFC 3339). */
  listHeartbeat?: (ms: number) => unknown
  /** Status reads take this long once the daemon runs; from the second such read on, the daemon beats as each
   * returns (unless `heartbeat` is false). */
  statusDelayMs?: number
  /** Per status read once the daemon runs: how long each takes (overrides statusDelayMs). */
  statusDelays?: number[]
  /** tar archives everything but warns on stderr (as it does for a socket), exiting 0. */
  tarWarning?: string
  /** The join is this shell script, run as a real child by realDeps (its exit code and output are the join's). */
  joinScript?: string
}

/** A GNU tar archive of `files` (path -> text) relative to HOME, as `tar -C HOME -cf - .` writes it. */
function tarOf(files: Record<string, string>): string {
  // Names and bodies as their UTF-8 bytes, one character per byte, as tar writes them and realDeps reads them.
  const bytes = (text: string) => Buffer.from(text, "utf8").toString("latin1")
  const block = (text: string) => text + "\0".repeat((512 - (text.length % 512)) % 512)
  const header = (name: string, size: number, type: string) => {
    const pad = (text: string, n: number) => (text + "\0".repeat(n)).slice(0, n)
    const h = pad(name, 100) + pad("0000644", 8) + pad("0001750", 8) + pad("0001750", 8) + pad(size.toString(8).padStart(11, "0"), 12) + pad("15000000000", 12) + "        " + type
    return pad(h + pad("", 100) + "ustar  \0", 512)
  }
  let out = header("./", 0, "5")
  for (const [path, text] of Object.entries(files)) {
    const name = bytes(`./${path.slice(HOME.length + 1)}`)
    const body = bytes(text)
    if (name.length > 100) out += header("././@LongLink", name.length + 1, "L") + block(`${name}\0`)
    out += header(name.slice(0, 100), body.length, "0") + block(body)
  }
  return out + "\0".repeat(1024)
}

/** One fake world: the stack, cmux-api, the platform, sudo and acpmux. Records every call. */
function world(k: Knobs = {}) {
  let clock = Date.parse("2026-10-29T12:00:00Z")
  const calls: Array<{ method: string; url: string; headers: Record<string, string>; body: string }> = []
  const runs: Array<{ argv: string[]; env: Record<string, string>; stdin?: string }> = []
  const lines: string[] = []
  const files: Record<string, string> = {}
  let joined = false
  let daemonUp = false
  let lastHeartbeat: number | null = null
  let revoked = false
  let revokeCalls = 0
  let redeemed = false
  let listReads = 0
  const revokedIds: string[] = []
  const kills: string[] = []
  let releaseJoin: (() => void) | undefined
  const listAt: number[] = []
  const revokeAt: number[] = []
  let aborted = 0
  let releasedAt: number | null = null
  // Virtual time. Every fake answers in microtasks, so the clock moves only when nothing else can run:
  // to the next timer due (sleeps, slow answers). Request timeouts are deadlines that abort as the clock
  // passes them; they never move it. A dropped sleep (its signal aborted) never moves it either.
  const timers: Array<{ at: number; fire: () => void; active: boolean }> = []
  const deadlines: Array<{ at: number; controller: AbortController }> = []
  let ticking = false
  const tick = () => {
    ticking = false
    const due = timers.filter((t) => t.active)
    if (due.length === 0) return
    clock = Math.max(clock, Math.min(...due.map((t) => t.at)))
    for (const d of deadlines) if (!d.controller.signal.aborted && d.at <= clock) d.controller.abort(new DOMException("timed out", "TimeoutError"))
    for (const t of due)
      if (t.at <= clock) {
        t.active = false
        t.fire()
      }
    kick()
  }
  const kick = () => {
    if (!ticking) {
      ticking = true
      setImmediate(tick)
    }
  }
  const after = (ms: number, signal?: AbortSignal) =>
    new Promise<void>((resolve) => {
      if (signal?.aborted) return
      const t = { at: clock + ms, fire: resolve, active: true }
      signal?.addEventListener("abort", () => (t.active = false), { once: true })
      timers.push(t)
      kick()
    })
  // A held join told to stop: it ends (and its redeem has landed) after joinLingersMs.
  const stopJoin = () => {
    if (!releaseJoin) return
    const release = releaseJoin
    releaseJoin = undefined
    const end = () => {
      releasedAt = clock
      release()
    }
    if (k.joinLingersMs) void after(k.joinLingersMs).then(end)
    else end()
  }

  const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
  const fetch = async (url: string, init: RequestInit) => {
    const headers = Object.fromEntries(Object.entries((init.headers ?? {}) as Record<string, string>).map(([a, b]) => [a.toLowerCase(), b]))
    const body = typeof init.body === "string" ? init.body : ""
    calls.push({ method: init.method ?? "GET", url, headers, body })
    const parsed = body ? JSON.parse(body) : {}
    if (url.endsWith("/auth/password/sign-in")) return json(200, { access_token: STACK_ACCESS, refresh_token: STACK_REFRESH, user_id: "stack-user" })
    if (url.endsWith("/auth/sessions/current")) return json(200, {})
    if (url === `${DEV_API}/v1/ops`) {
      if (headers.authorization !== `Bearer ${STACK_ACCESS}`) return json(401, { code: "auth.unauthorized" })
      k.onOp?.(parsed.op)
      if (parsed.op === "install.register" && k.registerDelayMs) {
        const done = await Promise.race([
          after(k.registerDelayMs).then(() => "answered"),
          new Promise<string>((resolve) => init.signal?.addEventListener("abort", () => resolve("aborted"), { once: true }))
        ])
        if (done === "aborted") throw new DOMException("aborted", "AbortError")
      }
      const value = parsed.op === "user.ensure" ? { id: "user_1" } : parsed.op === "install.register" ? { id: "inst_1" } : { id: "inst_1", revoked: true }
      return json(200, { ok: true, value })
    }
    if (url === `${DEV_API}/v1/auth/challenge`) return json(200, { nonce: "n1", message_prefix: "cmux-auth:v1:development:inst_1:", install: "inst_1" })
    if (url === `${DEV_API}/v1/auth/token`) return json(200, { access_token: ACCESS, expires_at: clock + 600_000, team: "team_1" })
    if (!url.startsWith(DEV_PLATFORM)) return json(404, {})
    if (headers.authorization !== `Bearer ${ACCESS}`) return json(401, { code: "machine.unauthorized" })
    const path = url.slice(DEV_PLATFORM.length)
    if (path === "/v1/machines/join-tokens") {
      if (k.mintStatus === 400) return json(400, { code: `bad ${TOKEN}`, message: `echo ${TOKEN}` })
      if (k.mintStatus && k.mintStatus !== 200) return json(k.mintStatus, { code: "join.rate_limited", message: `echo ${TOKEN}` })
      return json(200, { token: TOKEN, ...(k.noJoinTokenId ? {} : { joinTokenId: "jt_1" }), expiresAt: "2026-10-29T12:10:00Z", teamId: "team_1", label: parsed.label })
    }
    if (path === "/v1/machines/credentials") {
      listAt.push(clock)
      if (k.listDelayMs) {
        // The read ends at its delay, at its own timeout or on its abort, whichever comes first.
        const own = deadlines[deadlines.length - 1]!
        const drop = new AbortController()
        await Promise.race([
          after(Math.max(0, Math.min(clock + k.listDelayMs, own.at) - clock), drop.signal),
          new Promise((resolve) => init.signal?.addEventListener("abort", resolve, { once: true }))
        ])
        drop.abort()
        if (init.signal?.aborted) {
          aborted += 1
          throw new DOMException("aborted", "AbortError")
        }
      }
      listReads += 1
      const visible = (joined || redeemed) && (redeemed ? listReads > (k.listVisibleAfter ?? 0) : true)
      const ours = visible ? [{ machineId: "m_1", joinTokenId: "jt_1", teamId: "team_1", label: "ci-join-1", mintedBy: "user_1", createdAt: new Date(clock).toISOString(), lastHeartbeat: lastHeartbeat ? (k.listHeartbeat ?? ((ms: number) => new Date(ms).toISOString()))(lastHeartbeat) : null, revoked }] : []
      const others = (k.others ?? []).map((m) => ({ ...m, revoked: m.revoked === true || revokedIds.includes(String(m.machineId)) }))
      return json(200, { machines: [...others, ...ours] })
    }
    const revoke = /^\/v1\/machines\/credentials\/([^/]+)\/revoke$/.exec(path)
    if (revoke && revoke[1] !== "m_1") {
      revokedIds.push(revoke[1]!)
      return new Response(null, { status: 204 })
    }
    if (path === "/v1/machines/credentials/m_1/revoke") {
      revokeCalls += 1
      revokeAt.push(clock)
      if (k.hangFirstRevoke && revokeCalls === 1) {
        k.onRevoke?.()
        await new Promise((_, reject) => {
          if (init.signal?.aborted) reject(new DOMException("aborted", "AbortError"))
          init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))
        })
      }
      if (k.revokeStatus && k.revokeStatus !== 204) return json(k.revokeStatus, { code: "machine.join.unavailable" })
      revoked = true
      return new Response(null, { status: 204 })
    }
    return json(404, { code: "machine.not_found" })
  }

  let daemonStatusReads = 0
  let daemonStartedAt: number | null = null
  // Once the daemon runs: when each status read started and ended.
  const statusReads: Array<{ start: number; end: number }> = []
  const acpmux = async (args: string[], stdin: string | undefined, signal?: AbortSignal, timeoutMs = 60_000): Promise<ChildResult> => {
    if (args.join(" ") === "host join --status --json") {
      const delay = daemonUp ? (k.statusDelays?.[daemonStatusReads] ?? k.statusDelayMs) : undefined
      if (delay !== undefined) {
        daemonStatusReads += 1
        const start = clock
        // A read past its timeout is killed, as realDeps kills it.
        if (delay > timeoutMs) {
          await after(timeoutMs)
          statusReads.push({ start, end: clock })
          return { code: null, stdout: "", stderr: "" }
        }
        await after(delay)
        statusReads.push({ start, end: clock })
        if (daemonStatusReads >= 2 && k.heartbeat !== false) lastHeartbeat = clock
      }
      if (k.statusFailsWithDaemon && daemonUp) return { code: 1, stdout: "", stderr: "status failed\n" }
      const status = {
        credentialPresent: joined,
        machineId: joined ? "m_1" : "",
        teamId: joined ? "team_1" : "",
        hubOrigin: DEV_PLATFORM,
        hubReachable: joined,
        lastHeartbeat: lastHeartbeat === null ? null : (k.heartbeatValue ?? String)(lastHeartbeat),
        revoked,
        consent: { screen: k.consentScreen === undefined ? "none" : k.consentScreen, control: "none" },
        credentialPath: k.statusCredentialPath ?? CRED_PATH,
        joinIncomplete: false
      }
      // acpmux pretty-prints (cli/output.rs print_json).
      return { code: 0, stdout: `${JSON.stringify(status, null, 2)}\n`, stderr: "" }
    }
    if (args[0] === "host" && args[1] === "join") {
      if (stdin !== `${TOKEN}\n`) return { code: 2, stdout: "", stderr: "join token is malformed\n" }
      k.duringJoin?.()
      if (k.holdJoin) {
        // In flight until stopped; the redeem reached the platform before it ended.
        const held = new Promise<void>((resolve) => (releaseJoin = resolve))
        signal?.addEventListener("abort", stopJoin, { once: true })
        await held
        redeemed = true
        listReads = 0
        return { code: null, stdout: "", stderr: "" }
      }
      if (k.redeemThenExit) {
        redeemed = true
        listReads = 0
        return { code: k.redeemThenExit, stdout: "", stderr: "could not store the machine credential\n" }
      }
      if (k.joinScript) return realDeps().run(["/bin/sh", "-c", k.joinScript], { env: { PATH: CHILD_PATH }, timeoutMs: 10_000 })
      if (k.joinExit) return { code: k.joinExit, stdout: "", stderr: k.joinStderr ?? "this line was used or expired\n" }
      joined = true
      files[CRED_PATH] = k.credentialFile ?? JSON.stringify({ credential: CREDENTIAL, machine_id: "m_1" })
      return { code: 0, stdout: `${JSON.stringify({ joined: true, alreadyJoined: false, machineId: k.joinMachineId ?? "m_1", teamId: "team_1", name: "ci-join-1", hubOrigin: DEV_PLATFORM }, null, 2)}\n`, stderr: k.joinStderr ?? "" }
    }
    return { code: 64, stdout: "", stderr: "unknown\n" }
  }

  const deps: Deps = {
    fetch,
    run: async (argv, o) => {
      runs.push({ argv, env: o.env, ...(o.stdin === undefined ? {} : { stdin: o.stdin }) })
      if (argv.includes("/bin/kill")) {
        kills.push(argv.join(" "))
        if (k.killDelayMs) await after(k.killDelayMs)
        if (!k.launcherOnly) stopJoin()
        return { code: 0, stdout: "", stderr: "" }
      }
      // Every child runs as the disposable user: sudo -n -u USER -- /usr/bin/env -i -C HOME (5 assignments) PROGRAM ...
      if (argv[0] !== "sudo" || argv[2] !== "-u" || argv[5] !== "/usr/bin/env") return { code: 1, stdout: "", stderr: "not as the user" }
      const cmd = argv.slice(14)
      if (cmd[0] === opts.acpmux) return acpmux(cmd.slice(1), o.stdin, o.signal, o.timeoutMs)
      if (cmd[0] === "cat") {
        if (k.catFails && cmd[2] !== CRED_PATH) return { code: 1, stdout: "", stderr: "Permission denied" }
        return { code: 0, stdout: files[cmd[2]!] ?? "", stderr: "" }
      }
      if (cmd[0] === "stat")
        return {
          code: 0,
          stdout: `${HOME}/.acpmux|${k.stateDirStat ?? `directory|${opts.user}|2|700`}\n${CRED_PATH}|${(!daemonUp && k.credentialStatBeforeDaemon) || k.credentialStat || `regular file|${opts.user}|1|600`}\n`,
          stderr: ""
        }
      if (cmd[0] === "tar") {
        if (k.catFails) return { code: 2, stdout: "", stderr: "tar: ./.acpmux/config.json: Cannot open: Permission denied" }
        const home = Object.fromEntries(Object.entries(files).filter(([path]) => path.startsWith(`${HOME}/`)))
        const archive = tarOf(home)
        // Read as text, the archive's bytes would arrive UTF-8 decoded, as realDeps decodes text.
        return { code: 0, stdout: o.binary ? archive : Buffer.from(archive, "latin1").toString("utf8"), stderr: k.tarWarning ?? "" }
      }
      return { code: 1, stdout: "", stderr: "" }
    },
    start: (argv, o) => {
      runs.push({ argv, env: o.env })
      daemonUp = true
      daemonStartedAt = clock
      return {
        stop: async () => {
          if (k.daemonHangs) await new Promise<never>(() => undefined)
          daemonUp = false
          return { code: 0, stdout: "", stderr: "mesh relay: on, through https://cmux-platform-development.debussy.workers.dev\n" }
        }
      }
    },
    write: (line) => lines.push(line),
    writeFile: (path, text) => {
      files[`written:${path}`] = text
    },
    now: () => clock,
    timeout: (ms) => {
      const controller = new AbortController()
      deadlines.push({ at: clock + ms, controller })
      return controller.signal
    },
    sleep: async (ms, signal) => {
      if (k.hangSleepMs === ms) {
        k.onHang?.()
        return new Promise<void>(() => undefined)
      }
      await after(ms, signal)
      if (daemonUp && joined && k.heartbeat !== false && !revoked) lastHeartbeat = clock - 2_000
    }
  }
  // Files the run leaves in the disposable home.
  for (const [path, text] of Object.entries(k.homeFiles ?? {})) files[path] = text
  return {
    deps,
    calls,
    runs,
    lines,
    files,
    revokeCalls: () => revokeCalls,
    revokedIds,
    kills,
    listAt,
    revokeAt,
    aborted: () => aborted,
    releasedAt: () => releasedAt,
    daemonStartedAt: () => daemonStartedAt,
    statusReads,
    now: () => clock,
    evidenceText: () => files[`written:${opts.evidence}`] ?? ""
  }
}

/** The runner's view of the log: only this script's own commands are commands, and none is ever switched off. */
function assertCommandsIntact(w: ReturnType<typeof world>) {
  let stopped: string | null = null
  for (const line of w.lines) {
    // The runner reads a v2 command at the start of a (trimmed) line and a v1 command (##[) anywhere.
    expect(line).not.toContain("##[")
    expect(line).not.toMatch(/[\r\n]/)
    const own = /^::(add-mask|warning|error)::/.test(line)
    if (!own) expect(line).not.toContain("::")
    if (stopped !== null) {
      if (line.trim() === `::${stopped}::`) stopped = null
      continue
    }
    const stop = /^::stop-commands::(.*)$/.exec(line.trim())
    if (stop) stopped = stop[1]!
  }
  expect(stopped).toBeNull()
}

/** What every run must hold, pass or fail. */
function assertNoSecretEscaped(w: ReturnType<typeof world>) {
  const evidence = w.evidenceText()
  expect(evidence.length).toBeGreaterThan(0)
  expect(evidenceLeaks(evidence, SECRETS)).toEqual([])
  for (const s of SECRETS) expect(evidence).not.toContain(s)
  expect(evidence.toLowerCase()).not.toContain("bearer")
  expect(evidence.toLowerCase()).not.toContain("authorization")
  for (const r of w.runs) {
    // Children get exactly a fixed PATH; argv never carries a secret.
    expect(r.env).toEqual({ PATH: CHILD_PATH })
    // Nothing runs as root: every child is the disposable user's.
    expect(r.argv.slice(0, 5)).toEqual(["sudo", "-n", "-u", opts.user, "--"])
    for (const s of SECRETS) expect(r.argv.join("\0")).not.toContain(s)
  }
  // Only the add-mask commands (swallowed by the runner) carry a value; they come before any other mention.
  for (const line of w.lines.filter((l) => !l.startsWith("::add-mask::"))) for (const s of SECRETS) expect(line).not.toContain(s)
  assertCommandsIntact(w)
  for (const c of w.calls) {
    expect(c.url).not.toContain("cmj_")
    expect(c.url).not.toContain("cmm_")
    for (const s of SECRETS) expect(c.url).not.toContain(s)
    // Only the platform and cmux-api's ops see a bearer; the platform's is the cmux access token.
    if (c.url.startsWith(DEV_PLATFORM)) expect(c.headers.authorization).toBe(`Bearer ${ACCESS}`)
  }
}

describe("refusals", () => {
  test("only the development platform origin", () => {
    expect(refusal(opts)).toBeUndefined()
    for (const origin of [
      "https://cmux-platform.debussy.workers.dev",
      "https://cmux-platform-staging.debussy.workers.dev",
      `${DEV_PLATFORM}/`,
      DEV_PLATFORM.replace("https", "http"),
      "https://platform.cmux.com",
      ""
    ])
      expect(refusal({ ...opts, origin })).toContain("origin must be")
  })

  test("a refused origin touches nothing", async () => {
    const w = world()
    await expect(runE2E({ ...opts, origin: "https://cmux-platform.debussy.workers.dev" }, env, w.deps)).rejects.toThrow("origin must be")
    expect(w.calls).toEqual([])
    expect(w.runs).toEqual([])
  })

  test("names, users and paths are plain", () => {
    expect(refusal({ ...opts, name: "a b" })).toContain("name")
    expect(refusal({ ...opts, name: "x".repeat(64) })).toContain("name")
    expect(refusal({ ...opts, user: "root" })).toContain("user")
    expect(refusal({ ...opts, user: "Bad;user" })).toContain("user")
    expect(refusal({ ...opts, home: "relative/home" })).toContain("home")
    expect(refusal({ ...opts, home: "/tmp/../etc" })).toContain("home")
  })

  test("missing stack secrets touch nothing", async () => {
    const w = world()
    await expect(runE2E(opts, {}, w.deps)).rejects.toThrow("CMUX_UITEST_STACK_EMAIL")
    expect(w.calls).toEqual([])
  })
})

describe("the full run", () => {
  test("passes with exactly the redacted evidence", async () => {
    const w = world()
    const e = await runE2E(opts, env, w.deps)
    expect(e.reason).toBe("joined, heartbeat, listed, consent none, mode 600, revoked, no secrets found")
    expect(e.result).toBe("pass")
    expect(Object.keys(JSON.parse(w.evidenceText())).sort()).toEqual(
      ["consent", "credentialFileMode", "hubOrigin", "joinTokenId", "list", "machineId", "name", "reason", "result", "revoke", "run", "secretScan", "status", "teamId"].sort()
    )
    expect(e).toMatchObject({
      hubOrigin: DEV_PLATFORM,
      machineId: "m_1",
      teamId: "team_1",
      joinTokenId: "jt_1",
      status: { credentialPresent: true, joinIncomplete: false, revoked: false, hubReachable: true },
      consent: { screen: "none", control: "none" },
      credentialFileMode: "600",
      list: { machineId: "m_1", revoked: false, lastHeartbeatPresent: true },
      secretScan: { home: { cmj: 0, cmm: 0, credentialFileCmm: 1 }, log: { cmj: 0, cmm: 0 }, evidence: { cmj: 0, cmm: 0 } },
      revoke: { revokedListed: true, statusRevoked: true }
    })
    expect(e.status.heartbeatAgeSeconds).toBeLessThan(90)
    assertNoSecretEscaped(w)
  })

  test("the join token reaches acpmux only on stdin, as the disposable user", async () => {
    const w = world()
    await runE2E(opts, env, w.deps)
    const join = w.runs.filter((r) => r.stdin !== undefined)
    expect(join).toHaveLength(1)
    expect(join[0]!.stdin).toBe(`${TOKEN}\n`)
    expect(join[0]!.argv.slice(0, 5)).toEqual(["sudo", "-n", "-u", opts.user, "--"])
    expect(join[0]!.argv).toContain("-i")
    expect(join[0]!.argv.slice(-8)).toEqual([opts.acpmux, "host", "join", "--hub", DEV_PLATFORM, "--name", opts.name, "--json"])
  })

  test("every value is masked before anything else is printed", async () => {
    const w = world()
    await runE2E(opts, env, w.deps)
    for (const s of [EMAIL, PASSWORD, STACK_ACCESS, STACK_REFRESH, ACCESS, TOKEN, CREDENTIAL]) expect(w.lines).toContain(`::add-mask::${s}`)
    // The join token is masked before the join process starts.
    const maskedAt = w.lines.indexOf(`::add-mask::${TOKEN}`)
    expect(maskedAt).toBeGreaterThanOrEqual(0)
    expect(w.lines.slice(0, maskedAt).some((l) => l.includes("joined as"))).toBe(false)
  })

  test("the machine and the install are revoked, and the session signed out", async () => {
    const w = world()
    await runE2E(opts, env, w.deps)
    expect(w.revokeCalls()).toBe(1)
    const ops = w.calls.filter((c) => c.url === `${DEV_API}/v1/ops`).map((c) => JSON.parse(c.body).op)
    expect(ops).toEqual(["user.ensure", "install.register", "install.revoke"])
    expect(w.calls.some((c) => c.method === "DELETE" && c.url.endsWith("/auth/sessions/current"))).toBe(true)
  })
})

describe("failure paths", () => {
  test("a refused mint fails without starting acpmux, and the install is revoked", async () => {
    const w = world({ mintStatus: 429 })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("mint: HTTP 429 join.rate_limited")
    expect(w.runs.filter((r) => r.argv.includes(opts.acpmux))).toEqual([])
    expect(w.calls.some((c) => c.body.includes("install.revoke"))).toBe(true)
    assertNoSecretEscaped(w)
  })

  test("a server code that is not a plain identifier is never echoed", async () => {
    const w = world({ mintStatus: 400 })
    const e = await runE2E(opts, env, w.deps)
    expect(e.reason.split("; ")[0]).toBe("mint: HTTP 400")
    assertNoSecretEscaped(w)
  })

  test("a used token (exit 3) fails and names the exit", async () => {
    const w = world({ joinExit: 3 })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("join: exit 3 (expired or used)")
    // Nothing was redeemed, so nothing is listed and nothing is revoked.
    expect(w.revokeCalls()).toBe(0)
    assertNoSecretEscaped(w)
  })

  test("no heartbeat fails and still revokes the joined machine", async () => {
    const w = world({ heartbeat: false })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("no heartbeat within 90 s")
    expect(w.revokeCalls()).toBe(1)
    expect(e.revoke.revokedListed).toBe(true)
    assertNoSecretEscaped(w)
  })

  test("a failed revoke is retried in cleanup and fails the run", async () => {
    const w = world({ revokeStatus: 503 })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("revoke: HTTP 503")
    expect(w.revokeCalls()).toBe(2)
    assertNoSecretEscaped(w)
  })

  test("acpmux printing the token fails the run, and the printed tail is redacted", async () => {
    const w = world({ joinExit: 4, joinStderr: `cannot reach the hub with ${TOKEN}\n` })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.secretScan.log.cmj).toBe(1)
    expect(e.reason).toContain("output holds a token or credential")
    expect(w.lines.some((l) => l.startsWith("  acpmux:") && l.includes("[secret]"))).toBe(true)
    assertNoSecretEscaped(w)
  })

  test("a credential copy outside the credential file fails the run", async () => {
    const w = world({ homeFiles: { [`${HOME}/.acpmux/daemon.log`]: `heartbeat with ${CREDENTIAL}` } })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.secretScan.home.cmm).toBe(1)
    expect(e.reason).toContain("the home holds a credential outside the credential file")
    assertNoSecretEscaped(w)
  })

  test("a token-shaped machineId from the join is never printed, put in a URL or the evidence", async () => {
    const shaped = `cmm_${"A".repeat(43)}`
    const w = world({ joinMachineId: shaped })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("join: no valid machineId")
    for (const line of w.lines) expect(line).not.toContain(shaped)
    for (const c of w.calls) expect(c.url).not.toContain(shaped)
    expect(w.evidenceText()).not.toContain(shaped)
    assertNoSecretEscaped(w)
  })

  test("an id or acpmux output shaped like a workflow command is printed as plain text", async () => {
    const w = world({ joinMachineId: "::stop-commands::pause", joinStderr: "::stop-commands::x\n##[add-mask]y\n::error::z\n" })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("join: no valid machineId")
    // The acpmux tail was printed, made plain.
    expect(w.lines.some((l) => l.includes("stop-commands"))).toBe(true)
    assertNoSecretEscaped(w)
  })

  test("a credential path other than the home's credential file is never read", async () => {
    const w = world({ statusCredentialPath: `${HOME}/.acpmux/../../../etc/shadow` })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("credential path is not the disposable home's credential file")
    expect(w.runs.filter((r) => r.argv.some((a) => a.includes("shadow")))).toEqual([])
    assertNoSecretEscaped(w)
  })

  test("a credential file written 644 by the join fails the run even if the daemon later narrows it to 600", async () => {
    const w = world({ credentialStatBeforeDaemon: `regular file|${opts.user}|1|644` })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("credential file mode is not 600 after the join")
    assertNoSecretEscaped(w)
  })

  test("a credential file with a hard link elsewhere, or a state directory that is a link, is never read", async () => {
    for (const k of [{ credentialStat: `regular file|${opts.user}|2|600` }, { stateDirStat: `symbolic link|${opts.user}|1|777` }]) {
      const w = world(k)
      const e = await runE2E(opts, env, w.deps)
      expect(e.result).toBe("fail")
      expect(e.reason).toContain("credential file is not the disposable user's own regular file, with one link, in its own state directory")
      expect(w.runs.filter((r) => r.argv.at(-1) === CRED_PATH && r.argv.at(-3) === "cat")).toEqual([])
      assertNoSecretEscaped(w)
    }
  })

  test("a credential file that is a link is never read", async () => {
    const w = world({ credentialStat: `symbolic link|${opts.user}|1|777` })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("credential file is not the disposable user's own regular file, with one link, in its own state directory")
    // The only reads of the credential path are the scan's, after cleanup; none before the check failed.
    const reads = w.runs.filter((r) => r.argv.at(-1) === CRED_PATH && r.argv.at(-3) === "cat")
    expect(reads.length).toBeLessThanOrEqual(1)
    assertNoSecretEscaped(w)
  })
})

describe("revoke on every path", () => {
  test("a mint without a joinTokenId never joins", async () => {
    const w = world({ noJoinTokenId: true })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("mint: no joinTokenId")
    expect(w.runs.filter((r) => r.argv.includes(opts.acpmux))).toEqual([])
    assertNoSecretEscaped(w)
  })

  test("a join that redeemed and then failed is found by its join token and revoked, even when listed late", async () => {
    const w = world({ redeemThenExit: 5, listVisibleAfter: 2 })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("join: exit 5 (store failed)")
    expect(w.revokeCalls()).toBe(1)
    expect(e.machineId).toBe("m_1")
    expect(e.revoke.revokedListed).toBe(true)
    assertNoSecretEscaped(w)
  })

  test("a cancel during the join waits for it, then revokes the machine it made", async () => {
    let cleanup: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    // The cancel lands once the join child is in flight (after this tick), as a signal would.
    const w = world({ duringJoin: () => queueMicrotask(() => (cancelled = cleanup!())) })
    const e = await runE2E(opts, env, w.deps, (c) => (cleanup = c))
    await cancelled
    expect(w.revokeCalls()).toBe(1)
    expect(e.revoke.revokedListed).toBe(true)
    assertNoSecretEscaped(w)
  })

  test("a credential file without a credential fails the run and still revokes", async () => {
    const w = world({ credentialFile: JSON.stringify({ machine_id: "m_1" }) })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("credential file holds no credential")
    expect(w.revokeCalls()).toBe(1)
    assertNoSecretEscaped(w)
  })

  test("the stack email and password are masked before the sign-in", async () => {
    const w = world()
    await runE2E(opts, env, w.deps)
    expect(w.lines.slice(0, 2)).toEqual([`::add-mask::${EMAIL}`, `::add-mask::${PASSWORD}`])
  })
})

describe("cancellation, the sweep, masking and the scan", () => {
  test("a cancel while the join is still in flight kills it, then finds the redeemed machine and revokes it", async () => {
    let cancel: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    const w = world({ holdJoin: true, listVisibleAfter: 1, duringJoin: () => queueMicrotask(() => (cancelled = cancel!())) })
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    await cancelled
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("cancelled")
    // TERM then KILL to the disposable user's processes, as that user, before the revoke.
    expect(w.kills).toEqual([`sudo -n -u ${opts.user} -- /bin/kill -TERM -1`, `sudo -n -u ${opts.user} -- /bin/kill -KILL -1`])
    expect(w.revokeCalls()).toBe(1)
    expect(e.machineId).toBe("m_1")
    // Nothing of the disposable user starts after the cancel: no status, no daemon.
    const after = w.runs.slice(w.runs.findIndex((r) => r.argv.includes("/bin/kill")))
    expect(after.filter((r) => r.argv.includes(opts.acpmux))).toEqual([])
    assertNoSecretEscaped(w)
  })

  test("after a cancel, a machine listed late is still revoked before the deadline", async () => {
    let cancel: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    let cancelAt = 0
    const w = world({
      holdJoin: true,
      listVisibleAfter: 1,
      listDelayMs: 1_500,
      duringJoin: () => queueMicrotask(() => ((cancelAt = w.now()), (cancelled = cancel!())))
    })
    await runE2E(opts, env, w.deps, (c) => (cancel = c))
    await cancelled
    expect(w.revokeCalls()).toBe(1)
    expect(w.lines).toContain("revoked machine m_1")
    expect(w.revokeAt[0]! - cancelAt).toBeLessThan(CANCEL_BUDGET_MS)
  })

  test("after a cancel, the search for an unlisted machine stops in time for a revoke", async () => {
    let cancel: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    let cancelAt = 0
    const w = world({
      holdJoin: true,
      listVisibleAfter: 100,
      listDelayMs: 1_500,
      duringJoin: () => queueMicrotask(() => ((cancelAt = w.now()), (cancelled = cancel!())))
    })
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    await cancelled
    expect(w.revokeCalls()).toBe(0)
    const searches = w.listAt.filter((t) => t >= cancelAt)
    expect(searches.length).toBeGreaterThan(0)
    // Every read starts early enough to leave the revoke its reserve.
    for (const t of searches) expect(t - cancelAt).toBeLessThanOrEqual(CANCEL_BUDGET_MS - REVOKE_RESERVE_MS)
    // The last read ran into its shortened budget and was aborted, not waited out.
    expect(w.aborted()).toBeGreaterThanOrEqual(1)
    expect(w.now() - cancelAt).toBeLessThanOrEqual(CANCEL_BUDGET_MS)
    expect(e.result).toBe("fail")
  })

  test("a cancel during cleanup's wait for the daemon to exit ends the wait, kills it and revokes", async () => {
    let cancel: (() => Promise<void>) | undefined
    const w = world({
      statusFailsWithDaemon: true,
      daemonHangs: true,
      hangSleepMs: 10_000,
      onHang: () => queueMicrotask(() => void cancel!())
    })
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    expect(e.reason).toContain("cancelled")
    expect(w.kills.at(-1)).toBe(`sudo -n -u ${opts.user} -- /bin/kill -KILL -1`)
    expect(w.revokeCalls()).toBe(1)
    assertNoSecretEscaped(w)
  })

  test("a cancel waits for a join that ends only after slow kills, then finds and revokes its machine", async () => {
    let cancel: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    let cancelAt = 0
    let readsBefore = 0
    const w = world({
      holdJoin: true,
      killDelayMs: 300,
      joinLingersMs: 1_200,
      duringJoin: () => queueMicrotask(() => ((cancelAt = w.now()), (readsBefore = w.listAt.length), (cancelled = cancel!())))
    })
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    await cancelled
    expect(w.releasedAt()).not.toBeNull()
    // No search for the machine before its join had ended.
    const searches = w.listAt.slice(readsBefore)
    expect(searches.length).toBeGreaterThan(0)
    for (const t of searches) expect(t).toBeGreaterThanOrEqual(w.releasedAt()!)
    expect(w.revokeCalls()).toBe(1)
    expect(w.revokeAt[0]! - cancelAt).toBeLessThan(CANCEL_BUDGET_MS)
    expect(e.reason).not.toContain("had not stopped")
    assertNoSecretEscaped(w)
  })

  test("a join launcher the user's kills cannot reach is stopped by its own signal before the search", async () => {
    let cancel: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    let cancelAt = 0
    let readsBefore = 0
    const w = world({
      holdJoin: true,
      launcherOnly: true,
      joinLingersMs: 500,
      duringJoin: () => queueMicrotask(() => ((cancelAt = w.now()), (readsBefore = w.listAt.length), (cancelled = cancel!())))
    })
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    await cancelled
    expect(w.releasedAt()).toBe(cancelAt + 500)
    for (const t of w.listAt.slice(readsBefore)) expect(t).toBeGreaterThanOrEqual(w.releasedAt()!)
    expect(w.revokeCalls()).toBe(1)
    expect(e.reason).not.toContain("had not stopped")
    assertNoSecretEscaped(w)
  })

  test("a join that does not stop is reported, and the search still leaves the revoke its reserve", async () => {
    let cancel: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    let cancelAt = 0
    let readsBefore = 0
    let cleanedAt = 0
    const w = world({
      holdJoin: true,
      launcherOnly: true,
      joinLingersMs: 60_000,
      duringJoin: () => queueMicrotask(() => ((cancelAt = w.now()), (readsBefore = w.listAt.length), (cancelled = cancel!().then(() => void (cleanedAt = w.now())))))
    })
    // The run itself returns only once the stuck join ends; in production main() has exited 9 s after
    // the signal. What must hold is that cleanup, revoke search included, is done within the budget.
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    await cancelled
    expect(e.reason).toContain("the join process had not stopped before the search for its machine")
    const searches = w.listAt.slice(readsBefore)
    for (const t of searches) expect(t - cancelAt).toBeLessThanOrEqual(CANCEL_BUDGET_MS - REVOKE_RESERVE_MS)
    // Paced reads, never back to back as the deadline nears.
    for (let i = 1; i < searches.length; i++) expect(searches[i]! - searches[i - 1]!).toBeGreaterThanOrEqual(100)
    expect(cleanedAt - cancelAt).toBeLessThanOrEqual(CANCEL_BUDGET_MS)
    assertNoSecretEscaped(w)
  })

  test("a cancel during cleanup's revoke aborts it and revokes again", async () => {
    let cancel: (() => Promise<void>) | undefined
    // The run fails before its own revoke (a bad credential file), so the first revoke is cleanup's.
    const w = world({ credentialFile: JSON.stringify({ machine_id: "m_1" }), hangFirstRevoke: true, onRevoke: () => queueMicrotask(() => void cancel!()) })
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    expect(w.revokeCalls()).toBe(2)
    expect(e.revoke.revokedListed).toBe(true)
    expect(e.reason).toContain("cancelled")
    assertNoSecretEscaped(w)
  })

  test("a custom name keeps the run's label, so the sweep can find the machine", async () => {
    const w = world()
    const e = await runE2E({ ...opts, name: "smoke-test" }, env, w.deps)
    const mint = w.calls.find((c) => c.url.endsWith("/v1/machines/join-tokens"))!
    expect(JSON.parse(mint.body).label).toBe("ci-join-1")
    const join = w.runs.find((r) => r.stdin !== undefined)!
    expect(join.argv.slice(-3)).toEqual(["--name", "smoke-test", "--json"])
    expect(e.name).toBe("smoke-test")
  })

  test("the sweep revokes only this account's stale CI machines", async () => {
    const old = "2026-10-29T10:00:00Z"
    const w = world({
      others: [
        { machineId: "m_stale", joinTokenId: "jt_0", label: "ci-join-40000", mintedBy: "user_1", createdAt: old, revoked: false },
        { machineId: "m_human", joinTokenId: "jt_h", label: "lane-vm-3", mintedBy: "user_1", createdAt: old, revoked: false },
        { machineId: "m_other", joinTokenId: "jt_o", label: "ci-join-40001", mintedBy: "user_2", createdAt: old, revoked: false },
        { machineId: "m_done", joinTokenId: "jt_d", label: "ci-join-40002", mintedBy: "user_1", createdAt: old, revoked: true }
      ]
    })
    // The fake clock starts at 12:00, two hours after these rows were made.
    const e = await runE2E(opts, env, w.deps)
    expect(w.revokedIds).toEqual(["m_stale"])
    expect(w.lines).toContain("revoked 1 machine(s) an earlier interrupted run left joined")
    expect(e.result).toBe("pass")
  })

  test("a password with a newline and a percent sign is masked escaped, line by line", async () => {
    const password = "p%0Ass\nline2"
    const w = world()
    await runE2E(opts, { ...env, CMUX_UITEST_STACK_PASSWORD: password }, w.deps)
    expect(w.lines).toContain("::add-mask::p%250Ass%0Aline2")
    expect(w.lines).toContain("::add-mask::p%250Ass")
    expect(w.lines).toContain("::add-mask::line2")
    for (const line of w.lines.filter((l) => !l.startsWith("::add-mask::"))) expect(line).not.toContain("line2")
    expect(w.evidenceText()).not.toContain("line2")
  })

  test("a file named after a credential fails the scan, and no file name reaches an argv", async () => {
    const w = world({ homeFiles: { [`${HOME}/.acpmux/${CREDENTIAL}`]: "" } })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.secretScan.home.cmm).toBe(1)
    expect(e.reason).toContain("the home holds a credential outside the credential file")
    // The scan is one tar with a fixed argv; no run names a file under the home but the credential file.
    for (const r of w.runs) for (const a of r.argv) if (a.startsWith(`${HOME}/`)) expect([CRED_PATH, `${HOME}/.acpmux`]).toContain(a)
    assertNoSecretEscaped(w)
  })

  test("a sign-in or token value left in the home fails the run", async () => {
    const w = world({ homeFiles: { [`${HOME}/.acpmux/cache.json`]: `{"t":"${ACCESS}"}` } })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("the home holds a value of this run's sign-in or tokens")
    assertNoSecretEscaped(w)
  })

  test("a home entry tar skips with a warning (a socket) fails the scan", async () => {
    const w = world({ tarWarning: `tar: ./.acpmux/${CREDENTIAL}: socket ignored\n` })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("could not scan the whole disposable home")
    expect(e.secretScan.home.cmm).toBeNull()
    assertNoSecretEscaped(w)
  })

  test("an incomplete home scan fails the run", async () => {
    const w = world({ catFails: true, homeFiles: { [`${HOME}/.acpmux/config.json`]: "{}" } })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("could not scan the whole disposable home")
    expect(e.secretScan.home.cmj).toBeNull()
    assertNoSecretEscaped(w)
  })
})

// A synthetic non-ASCII held value: its text and its UTF-8 bytes (one character per byte) differ.
const UPW = "pässwörd-ünïcode-123"
const uenv = { ...env, CMUX_UITEST_STACK_PASSWORD: UPW }
const UPW_BYTES = Buffer.from(UPW, "utf8").toString("latin1")
const octal = (text: string) => [...Buffer.from(text, "utf8")].map((b) => `\\${b.toString(8).padStart(3, "0")}`).join("")

/** Neither form of the non-ASCII value is printed (masks aside), put in an argv or URL, or in the evidence. */
function assertUnicodeHeld(w: ReturnType<typeof world>) {
  expect(w.lines).toContain(`::add-mask::${UPW}`)
  expect(w.lines).toContain(`::add-mask::${UPW_BYTES}`)
  for (const form of [UPW, UPW_BYTES]) {
    for (const line of w.lines.filter((l) => !l.startsWith("::add-mask::"))) expect(line).not.toContain(form)
    for (const r of w.runs) expect(r.argv.join("\0")).not.toContain(form)
    for (const c of w.calls) expect(c.url).not.toContain(form)
    expect(w.evidenceText()).not.toContain(form)
  }
}

describe("killed children", () => {
  test("a timed-out child answers within the kill grace even if a descendant holds its pipes", async () => {
    // The shell prints its background sleep's pid, then waits; the sleep keeps stdout and stderr open.
    const started = Date.now()
    const r = await realDeps().run(["/bin/sh", "-c", "sleep 30 & echo $! >&2; wait"], { env: { PATH: CHILD_PATH }, timeoutMs: 300 })
    const took = Date.now() - started
    const orphan = Number(r.stderr.trim())
    if (Number.isInteger(orphan) && orphan > 0) {
      try {
        process.kill(orphan, "SIGKILL")
      } catch {}
    }
    expect(r.code).toBeNull()
    expect(took).toBeLessThan(300 + KILL_GRACE_MS + 1_000)
  })
})

describe("non-ASCII held values", () => {
  test("child text output is read as UTF-8, and binary output keeps each byte", async () => {
    const script = `printf '${octal("xäy")}'; printf '${octal("päss")}' >&2`
    const text = await realDeps().run(["/bin/sh", "-c", script], { env: { PATH: CHILD_PATH }, timeoutMs: 10_000 })
    expect(text.stdout).toBe("xäy")
    expect(text.stderr).toBe("päss")
    const binary = await realDeps().run(["/bin/sh", "-c", script], { env: { PATH: CHILD_PATH }, timeoutMs: 10_000, binary: true })
    expect(binary.stdout).toBe("x\u00c3\u00a4y")
    expect(binary.stderr).toBe("päss")
    expect(byteForm("xäy")).toBe("x\u00c3\u00a4y")
  })

  test("one stored as UTF-8 in a home file's body fails the scan", async () => {
    const w = world({ homeFiles: { [`${HOME}/.acpmux/cache.json`]: `{"p":"${UPW}"}` } })
    const e = await runE2E(opts, uenv, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("the home holds a value of this run's sign-in or tokens")
    assertUnicodeHeld(w)
  })

  test("one stored as UTF-8 in a home file's name fails the scan", async () => {
    const w = world({ homeFiles: { [`${HOME}/.acpmux/${UPW}.txt`]: "" } })
    const e = await runE2E(opts, uenv, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("the home holds a value of this run's sign-in or tokens")
    assertUnicodeHeld(w)
  })

  test("one a real child prints as UTF-8 on stderr is redacted from the printed tail and fails the run", async () => {
    const w = world({ joinScript: `printf 'cannot reach the hub with ${octal(UPW)}\\n' >&2; exit 4` })
    const e = await runE2E(opts, uenv, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("join: exit 4 (hub unreachable)")
    expect(e.reason).toContain("output holds a secret value")
    expect(w.lines.some((l) => l.startsWith("  acpmux: cannot reach the hub with [secret]"))).toBe(true)
    assertUnicodeHeld(w)
  })
})

describe("consent and escaped values", () => {
  test("a consent value other than none or granted is recorded as null, never echoed", async () => {
    // A password with JSON-special characters, echoed back as the consent value.
    const password = 'pa"ss\\word\nline-two'
    const w = world({ consentScreen: password })
    const e = await runE2E(opts, { ...env, CMUX_UITEST_STACK_PASSWORD: password }, w.deps)
    expect(e.result).toBe("fail")
    expect(e.consent).toEqual({ screen: null, control: "none" })
    expect(e.reason).toContain("consent is not none for both screen and control")
    const text = w.evidenceText()
    expect(text).not.toContain(JSON.stringify(password).slice(1, -1))
    expect(text).not.toContain("line-two")
    assertNoSecretEscaped(w)
  })

  test("evidenceLeaks finds a held value in its JSON-escaped form", () => {
    const held = 'se"cret\\val\nue'
    expect(evidenceLeaks(JSON.stringify({ x: held }), [held])).toContain("held secret")
  })
})

describe("heartbeats", () => {
  test("a read without a beat just before the deadline: the pause ends at the deadline", async () => {
    // Read 1 takes 59 s, the pause 3 s, read 2 27 s: it ends at 89 s with no beat, leaving 1 s for the pause.
    const w = world({ heartbeat: false, statusDelays: [59_000, 27_000] })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    const deadline = w.daemonStartedAt()! + 90_000
    expect(w.statusReads.map((r) => r.end - w.daemonStartedAt()!)).toEqual([59_000, 89_000])
    // The next step (the platform's list; the sweep's read came at the daemon's start instant) starts at the
    // deadline, not 3 s past it.
    const nextList = w.listAt.find((t) => t > w.daemonStartedAt()!)!
    expect(nextList).toBe(deadline)
    assertNoSecretEscaped(w)
  })

  test("a status read that times out at the heartbeat deadline is not retried past it", async () => {
    // Read 1 takes 40 s (no beat); after the 3 s pause, read 2 hangs and is cut at the deadline (90 s).
    const w = world({ heartbeat: false, statusDelays: [40_000, 600_000, 1_000] })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.status.heartbeatAgeSeconds).toBeNull()
    const deadline = w.daemonStartedAt()! + 90_000
    expect(w.statusReads.length).toBe(2)
    expect(w.statusReads[1]!.end).toBe(deadline)
    for (const r of w.statusReads) expect(r.end).toBeLessThanOrEqual(deadline)
    assertNoSecretEscaped(w)
  })

  test("slow status reads cannot carry the check past its deadline", async () => {
    const w = world({ statusDelayMs: 55_000 })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.status.heartbeatAgeSeconds).toBeNull()
    assertNoSecretEscaped(w)
  })

  test("a status heartbeat in the future does not count", async () => {
    const w = world({ heartbeatValue: (ms) => String(ms + 600_000) })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("no heartbeat within 90 s (status showed a heartbeat time outside the daemon's run)")
    expect(e.status.heartbeatAgeSeconds).toBeNull()
    assertNoSecretEscaped(w)
  })

  test("a status heartbeat in microseconds does not count", async () => {
    const w = world({ heartbeatValue: (ms) => String(ms * 1000) })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("no heartbeat within 90 s")
    assertNoSecretEscaped(w)
  })

  test("a listed heartbeat from before the daemon started does not count", async () => {
    const w = world({ listHeartbeat: () => "2026-10-01T00:00:00Z" })
    const e = await runE2E(opts, env, w.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("list: no heartbeat")
    assertNoSecretEscaped(w)
  })

  test("a listed heartbeat in epoch seconds or ms counts", async () => {
    for (const listHeartbeat of [(ms: number) => Math.floor(ms / 1000), (ms: number) => ms, (ms: number) => String(ms)]) {
      const w = world({ listHeartbeat })
      const e = await runE2E(opts, env, w.deps)
      expect(e.result).toBe("pass")
    }
  })

  test("heartbeatMs reads seconds, ms and RFC 3339, and nothing else", () => {
    expect(heartbeatMs(1_793_275_200)).toBe(1_793_275_200_000)
    expect(heartbeatMs(1_793_275_200_000)).toBe(1_793_275_200_000)
    expect(heartbeatMs("1793275200000")).toBe(1_793_275_200_000)
    expect(heartbeatMs("2026-10-29T12:00:00Z")).toBe(Date.parse("2026-10-29T12:00:00Z"))
    for (const bad of [null, undefined, "", "soon", "12:00", -5, 0, Number.NaN, {}]) expect(heartbeatMs(bad)).toBeNull()
  })
})

describe("cancellation during sign-in", () => {
  test("a cancel during user.ensure stops before the key and the install, and signs out", async () => {
    let cancel: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    const w = world({ onOp: (op) => void (op === "user.ensure" && (cancelled = cancel!())) })
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    await cancelled
    const ops = w.calls.filter((c) => c.url === `${DEV_API}/v1/ops`).map((c) => JSON.parse(c.body).op)
    expect(ops).toEqual(["user.ensure"])
    expect(w.calls.some((c) => c.method === "DELETE" && c.url.endsWith("/auth/sessions/current"))).toBe(true)
    expect(e.result).toBe("fail")
    assertNoSecretEscaped(w)
  })

  test("a cancel during install.register does not abort it: its late answer is still revoked", async () => {
    let cancel: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    // The server commits the install; its answer reaches us 1 s after the cancel.
    const w = world({ registerDelayMs: 1_000, onOp: (op) => void (op === "install.register" && (cancelled = cancel!())) })
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    await cancelled
    const ops = w.calls.filter((c) => c.url === `${DEV_API}/v1/ops`).map((c) => JSON.parse(c.body).op)
    expect(ops).toEqual(["user.ensure", "install.register", "install.revoke"])
    expect(e.result).toBe("fail")
    assertNoSecretEscaped(w)
  })

  test("an install registered while cleanup has begun is still revoked", async () => {
    let cancel: (() => Promise<void>) | undefined
    let cancelled: Promise<void> | undefined
    const w = world({ onOp: (op) => void (op === "install.register" && (cancelled = cancel!())) })
    const e = await runE2E(opts, env, w.deps, (c) => (cancel = c))
    await cancelled
    const ops = w.calls.filter((c) => c.url === `${DEV_API}/v1/ops`).map((c) => JSON.parse(c.body).op)
    expect(ops).toEqual(["user.ensure", "install.register", "install.revoke"])
    expect(w.calls.filter((c) => c.url.includes("/v1/machines/")).length).toBe(0)
    expect(e.result).toBe("fail")
    assertNoSecretEscaped(w)
  })
})

describe("redaction helpers", () => {
  test("tarEntries reads names, GNU long names, link targets and bodies, and refuses a truncated archive", () => {
    const long = `${HOME}/.acpmux/${"d".repeat(120)}/file`
    const archive = tarOf({ [`${HOME}/a.txt`]: "hello", [long]: "x".repeat(600) })
    const entries = tarEntries(archive)
    expect(entries.map((e) => e.name)).toEqual(["./", "./a.txt", `./${long.slice(HOME.length + 1)}`])
    expect(entries[1]!.body).toBe("hello")
    expect(entries[2]!.body.length).toBe(600)
    expect(() => tarEntries(archive.slice(0, 700))).toThrow()
  })

  test("safeId keeps plain ids and refuses token shapes, paths and control characters", () => {
    for (const ok of ["m_1", "jt_1", "team_1", "ci-join-123", "01J9ZK-abc.def"]) expect(safeId(ok)).toBe(ok)
    for (const bad of [".", "..", "...", "::stop-commands::pause", "a:b", `cmm_${"A".repeat(20)}`, "x-cmj_abc", "eyJhbGciOi", "Bearer", "a/b", "../x", "a\nb", "a b", "", "x".repeat(129), 7, null, undefined, {}])
      expect(safeId(bad)).toBeNull()
  })

  test("evidenceLeaks finds every pattern", () => {
    expect(evidenceLeaks(`{"x":"${TOKEN}"}`, [])).toContain("join token prefix")
    expect(evidenceLeaks(`{"x":"${CREDENTIAL}"}`, [])).toContain("credential prefix")
    expect(evidenceLeaks(`{"x":"${ACCESS}"}`, [])).toContain("jwt")
    expect(evidenceLeaks(`{"x":"Bearer abc"}`, [])).toContain("auth header")
    expect(evidenceLeaks(`{"x":"${EMAIL}"}`, [EMAIL])).toContain("held secret")
    expect(evidenceLeaks(`{"result":"pass","teamId":"team_1"}`, SECRETS)).toEqual([])
  })

  test("redact removes held values, prefixed tokens and JWTs", () => {
    const out = redact(`a ${TOKEN} b ${CREDENTIAL} c ${ACCESS} d ${EMAIL}`, SECRETS)
    for (const s of SECRETS) expect(out).not.toContain(s)
    // A token nobody held (another run's) is still cut at its prefix.
    const other = redact(`x cmj_someOtherTokenValue123 y ${ACCESS}`, [])
    expect(other).toBe("x cmj_[redacted] y [jwt].YWNjZXNzc2lnbmF0dXJl")
  })
})
