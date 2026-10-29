import { describe, expect, test } from "bun:test"
import {
  CHILD_PATH,
  DEV_API,
  DEV_PLATFORM,
  type ChildResult,
  type Deps,
  type Options,
  evidenceLeaks,
  redact,
  refusal,
  runE2E
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
}

/** One fake world: the stack, cmux-api, the platform, sudo and acpmux. Records every call. */
function world(k: Knobs = {}) {
  let clock = 1_000_000
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
      listReads += 1
      const visible = (joined || redeemed) && (redeemed ? listReads > (k.listVisibleAfter ?? 0) : true)
      const machines = visible ? [{ machineId: "m_1", joinTokenId: "jt_1", teamId: "team_1", label: "ci-join-1", lastHeartbeat: lastHeartbeat ? "2026-10-29T12:01:00Z" : null, revoked }] : []
      return json(200, { machines })
    }
    if (path === "/v1/machines/credentials/m_1/revoke") {
      revokeCalls += 1
      if (k.revokeStatus && k.revokeStatus !== 204) return json(k.revokeStatus, { code: "machine.join.unavailable" })
      revoked = true
      return new Response(null, { status: 204 })
    }
    return json(404, { code: "machine.not_found" })
  }

  const acpmux = (args: string[], stdin: string | undefined): ChildResult => {
    if (args.join(" ") === "host join --status --json") {
      const status = {
        credentialPresent: joined,
        machineId: joined ? "m_1" : "",
        teamId: joined ? "team_1" : "",
        hubOrigin: DEV_PLATFORM,
        hubReachable: joined,
        lastHeartbeat: lastHeartbeat === null ? null : String(lastHeartbeat),
        revoked,
        consent: { screen: "none", control: "none" },
        credentialPath: CRED_PATH,
        joinIncomplete: false
      }
      // acpmux pretty-prints (cli/output.rs print_json).
      return { code: 0, stdout: `${JSON.stringify(status, null, 2)}\n`, stderr: "" }
    }
    if (args[0] === "host" && args[1] === "join") {
      if (stdin !== `${TOKEN}\n`) return { code: 2, stdout: "", stderr: "join token is malformed\n" }
      k.duringJoin?.()
      if (k.redeemThenExit) {
        redeemed = true
        listReads = 0
        return { code: k.redeemThenExit, stdout: "", stderr: "could not store the machine credential\n" }
      }
      if (k.joinExit) return { code: k.joinExit, stdout: "", stderr: k.joinStderr ?? "this line was used or expired\n" }
      joined = true
      files[CRED_PATH] = k.credentialFile ?? JSON.stringify({ credential: CREDENTIAL, machine_id: "m_1" })
      return { code: 0, stdout: `${JSON.stringify({ joined: true, alreadyJoined: false, machineId: "m_1", teamId: "team_1", name: "ci-join-1", hubOrigin: DEV_PLATFORM }, null, 2)}\n`, stderr: k.joinStderr ?? "" }
    }
    return { code: 64, stdout: "", stderr: "unknown\n" }
  }

  const deps: Deps = {
    fetch,
    run: async (argv, o) => {
      runs.push({ argv, env: o.env, ...(o.stdin === undefined ? {} : { stdin: o.stdin }) })
      const at = argv.indexOf(opts.acpmux)
      if (argv[0] === "sudo" && argv[2] === "-u" && at > 0) return acpmux(argv.slice(at + 1), o.stdin)
      const cmd = argv.slice(3)
      if (cmd[0] === "cat") return { code: 0, stdout: files[cmd[2]!] ?? "", stderr: "" }
      if (cmd[0] === "stat") return { code: 0, stdout: "600\n", stderr: "" }
      if (cmd[0] === "find") return { code: 0, stdout: Object.keys(files).map((f) => `${f}\0`).join(""), stderr: "" }
      return { code: 1, stdout: "", stderr: "" }
    },
    start: (argv, o) => {
      runs.push({ argv, env: o.env })
      daemonUp = true
      return {
        stop: async () => {
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
    sleep: async (ms) => {
      clock += ms
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
    evidenceText: () => files[`written:${opts.evidence}`] ?? ""
  }
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
    for (const s of SECRETS) expect(r.argv.join("\0")).not.toContain(s)
  }
  // Only the add-mask commands (swallowed by the runner) carry a value; they come before any other mention.
  for (const line of w.lines.filter((l) => !l.startsWith("::add-mask::"))) for (const s of SECRETS) expect(line).not.toContain(s)
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

describe("redaction helpers", () => {
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
