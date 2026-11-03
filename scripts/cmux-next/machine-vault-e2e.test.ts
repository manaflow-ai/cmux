import { describe, expect, test } from "bun:test"
import {
  CANCEL_BUDGET_MS,
  KILL_GRACE_MS,
  DEV_API,
  DEV_PLATFORM,
  KEY_VAR,
  NONCE_VAR,
  PROMPT,
  VAULT_CAPABILITY,
  type ChildResult,
  type Deps,
  type Options,
  lastJson,
  realDeps,
  refusal,
  replyText,
  runE2E
} from "./machine-vault-e2e.ts"

// Fake values shaped like the real ones; none is a real credential.
const EMAIL = "ci-account@example.invalid"
const PASSWORD = "fake-password-value"
const STACK_ACCESS = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJzdGFjay11c2VyIn0.c3RhY2tzaWduYXR1cmU"
const ACCESS = "eyJhbGciOiJFUzI1NiIsImtpZCI6ImsxIn0.eyJzdWIiOiJ1c2VyXzEifQ.YWNjZXNzc2lnbmF0dXJl"
const API_KEY = "sk-ant-api03-FAKEkeyVALUEfor-tests-0123456789"
const NONCE = "0123456789abcdef0123456789abcdef"
const HOME = "/Users/cmuxvault11"

const opts: Options = {
  origin: DEV_PLATFORM,
  cmux: "/tmp/mve.test/bin/cmux",
  user: "cmuxvault11",
  home: HOME,
  ssh: "/tmp/mve.test/bin/ssh",
  name: "ci-vault-1-1",
  work: "/tmp/mve.test",
  evidence: "/tmp/mve.test/evidence/evidence.json",
  runId: "1",
  sha: "a".repeat(40)
}

interface Knobs {
  noCapability?: boolean
  vaultEnv?: string[]
  reply?: string
  addExit?: number
  existingKey?: boolean
  /** A child prints this text (a leak). */
  leak?: string
  homeBody?: string
  /** More home files, name to body (latin1). */
  homeFiles?: Record<string, string>
  tarExit?: number
  tarStderr?: string
  /** install.revoke answers this status. */
  installRevokeStatus?: number
  /** `vault set NAME` waits for this promise before it answers (a write in flight). */
  holdSet?: Record<string, Promise<void>>
  /** `vault rm` leaves the entry (a failed removal). */
  rmFails?: boolean
  /** Requests whose URL (or ops op) includes this never answer until their signal aborts. */
  stall?: string[]
  /** The first `vault rm MACHINE_VAULT_E2E` hangs until its signal aborts. */
  firstRmHangs?: boolean
  /** Cleanup's `vault rm` and `vault ls` ignore their signal and answer only at their timeout plus the
   * kill grace, as a child that holds out to its SIGKILL does with the real runner. */
  cleanupCmdsHang?: boolean
  /** The agent run hangs until its signal aborts. */
  agentHangs?: boolean
  /** A revoke answers 200 but the machine stays live. */
  revokeNoop?: boolean
  /** The machine list answers this status. */
  listStatus?: number
  /** The earlier run's machine's revoke answers this status. */
  staleRevokeStatus?: number
  /** The Stack sign-out answers this status. */
  signOutStatus?: number
}

/** Resolves when `signal` aborts. */
const aborted = (signal: AbortSignal | undefined | null) =>
  new Promise<void>((resolve) => (signal?.aborted ? resolve() : signal?.addEventListener("abort", () => resolve(), { once: true })))

/** A tar archive of one regular file, as bsdtar's gnutar format writes it (enough for tarEntries). */
function tarOf(files: Record<string, string>): string {
  const parts: Buffer[] = []
  for (const [name, body] of Object.entries(files)) {
    const header = Buffer.alloc(512, 0)
    header.write(name, 0, "latin1")
    header.write(body.length.toString(8).padStart(11, "0"), 124, "latin1")
    header.write("0", 156, "latin1")
    const padded = Buffer.alloc(Math.ceil(body.length / 512) * 512, 0)
    padded.write(body, 0, "latin1")
    parts.push(header, padded)
  }
  return Buffer.concat([...parts, Buffer.alloc(1024, 0)]).toString("latin1")
}

function fakes(k: Knobs = {}) {
  const calls: string[][] = []
  const stdins: Record<string, string> = {}
  const files = new Map<string, string>()
  const removed: string[] = []
  const revoked: string[] = []
  const lines: string[] = []
  /** Every request, "METHOD url[ op]". */
  const requests: string[] = []
  let rms = 0
  const vault = new Set<string>(k.existingKey ? [KEY_VAR] : [])
  const ok = (stdout = ""): ChildResult => ({ code: 0, stdout, stderr: k.leak ?? "" })
  const deps: Deps = {
    fetch: async (url, init) => {
      const body = init.body ? JSON.parse(String(init.body)) : {}
      const json = (status: number, value: unknown) => new Response(JSON.stringify(value), { status })
      const label = `${init.method} ${url}${body.op ? ` ${body.op}` : ""}`
      requests.push(label)
      if (k.stall?.some((p) => label.includes(p))) {
        await aborted(init.signal)
        throw new DOMException("aborted", "AbortError")
      }
      if (url.endsWith("/auth/password/sign-in")) return json(200, { access_token: STACK_ACCESS, refresh_token: "fake-refresh-token-value" })
      if (url === `${DEV_API}/v1/ops`) {
        if (body.op === "user.ensure") return json(200, { ok: true, value: { id: "user_1" } })
        if (body.op === "install.register") return json(200, { ok: true, value: { id: "install_1" } })
        if (body.op === "install.revoke") return k.installRevokeStatus && k.installRevokeStatus !== 200 ? json(k.installRevokeStatus, { ok: false }) : json(200, { ok: true, value: {} })
      }
      if (url.endsWith("/v1/auth/challenge")) return json(200, { nonce: "n1", message_prefix: "p:" })
      if (url.endsWith("/v1/auth/token")) return json(200, { access_token: ACCESS, expires_at: Date.now() + 600_000 })
      if (url.endsWith("/v1/machines/credentials") && init.method === "GET") {
        if (k.listStatus) return json(k.listStatus, {})
        return json(200, {
          machines: [
            { machineId: "m_1", label: opts.name, revoked: revoked.includes("m_1"), joinTokenId: "jt_1", mintedBy: "user_1", createdAt: new Date().toISOString() },
            { machineId: "m_old", label: "ci-vault-0-1", revoked: revoked.includes("m_old"), mintedBy: "user_1", createdAt: new Date(Date.now() - 3_600_000).toISOString() },
            { machineId: "m_other", label: "laptop", revoked: false, mintedBy: "user_1", createdAt: new Date(0).toISOString() }
          ]
        })
      }
      const m = url.match(/\/v1\/machines\/credentials\/([^/]+)\/revoke$/)
      if (m) {
        const id = decodeURIComponent(m[1]!)
        if (id === "m_old" && k.staleRevokeStatus) return json(k.staleRevokeStatus, {})
        if (!k.revokeNoop) revoked.push(id)
        return json(200, {})
      }
      if (url.endsWith("/auth/sessions/current")) return json(k.signOutStatus ?? 200, {})
      return json(404, { code: "not_found" })
    },
    run: async (argv, { stdin, signal, timeoutMs }) => {
      calls.push(argv)
      const text = argv.join(" ")
      if (argv[0] === opts.cmux) {
        expect(argv.slice(-2)).toEqual(["--cloud-token-file", `${opts.work}/cloud-token`])
        expect(text).not.toContain(ACCESS)
        if (text.includes("vault ls")) return ok(JSON.stringify({ entries: [...vault].map((name) => ({ name, revision: 1 })) }))
        if (text.includes("vault set")) {
          const name = argv[argv.indexOf("set") + 1]!
          await k.holdSet?.[name]
          stdins[name] = stdin ?? ""
          vault.add(name)
          return ok("")
        }
        if (k.cleanupCmdsHang && (text.includes("vault rm") || (text.includes("vault ls") && rms > 0))) {
          rms++
          await Bun.sleep(timeoutMs + KILL_GRACE_MS)
          return { code: null, stdout: "", stderr: "" }
        }
        if (text.includes("vault rm")) {
          if (k.firstRmHangs && argv.includes(NONCE_VAR) && rms++ === 0) {
            await aborted(signal)
            return { code: null, stdout: "", stderr: "" }
          }
          if (!k.rmFails) vault.delete(argv[argv.indexOf("rm") + 1]!)
          return ok("")
        }
        if (text.includes("machine add")) {
          return { code: k.addExit ?? 0, stdout: JSON.stringify({ event: "joined", joinTokenId: "jt_1", vault: true, joined: { machineId: "m_1", name: "x" } }), stderr: k.leak ?? "" }
        }
      }
      if (argv[0] === "sudo") {
        if (text.includes("/bin/kill")) return ok()
        if (text.endsWith("acpmux capabilities")) return ok(k.noCapability ? "machine.join.stdin.v1\n" : `machine.join.stdin.v1\n${VAULT_CAPABILITY}\n`)
        if (text.includes("machine vault status")) {
          return ok(JSON.stringify({ joined: true, secretStore: "keychain", lastResult: "ok", env: (k.vaultEnv ?? [NONCE_VAR, KEY_VAR]).map((name) => ({ name, revision: 1 })) }, null, 2))
        }
        if (text.includes(" run ") && k.agentHangs) {
          await aborted(signal)
          return { code: null, stdout: "", stderr: "" }
        }
        if (text.includes(" run ")) return ok(JSON.stringify({ sessionId: "s", name: "n", reply: k.reply ?? `${NONCE}\n`, stopReason: "end_turn" }, null, 2))
        if (text.includes("/usr/bin/find")) return { code: 0, stdout: "", stderr: "" }
        if (text.includes("/usr/bin/tar")) {
          return { code: k.tarExit ?? 0, stdout: tarOf({ "./.zshenv": k.homeBody ?? "export X=1\n", ...k.homeFiles }), stderr: k.tarStderr ?? "" }
        }
      }
      return { code: 1, stdout: "", stderr: "unexpected" }
    },
    write: (line) => lines.push(line),
    writeFile: (path, text) => files.set(path, text),
    removeFile: (path) => {
      removed.push(path)
      files.delete(path)
    },
    now: () => Date.now(),
    sleep: (ms, signal) => Promise.race([Bun.sleep(ms), aborted(signal)]),
    random: () => NONCE
  }
  return { deps, calls, stdins, files, removed, revoked, lines, vault, requests }
}

const env = (apiKey = API_KEY) => ({ CMUX_UITEST_STACK_EMAIL: EMAIL, CMUX_UITEST_STACK_PASSWORD: PASSWORD, CMUX_E2E_ANTHROPIC_API_KEY: apiKey })

describe("machine-vault-e2e", () => {
  test("passes when the agent replies with the nonce, and cleans up", async () => {
    const f = fakes()
    const e = await runE2E(opts, env(), f.deps)
    expect(e.reason).toBe("vault set, joined over ssh, vault on the machine, the agent read it, cleaned up, no secrets found")
    expect(e.result).toBe("pass")
    expect(e.agentReply).toBe("pass")
    expect(e.nonce).toBe(NONCE)
    // Values go on stdin, never argv.
    expect(f.stdins[NONCE_VAR]).toBe(`${NONCE}\n`)
    expect(f.stdins[KEY_VAR]).toBe(`${API_KEY}\n`)
    for (const argv of f.calls) expect(argv.join(" ")).not.toContain(API_KEY)
    // The one command.
    const add = f.calls.find((a) => a.includes("add"))!
    expect(add.slice(1, 8)).toEqual(["--json", "machine", "add", "--vault", "--yes", "--name", opts.name])
    expect(add).toContain(`${opts.user}@localhost`)
    // The agent prompt and harness.
    const run = f.calls.find((a) => a.includes("run"))!
    expect(run).toContain(PROMPT)
    expect(run.slice(run.indexOf("-m"), run.indexOf("-m") + 2)).toEqual(["-m", "claude"])
    // This run's machine and the stale CI one, never another machine.
    expect(f.revoked.sort()).toEqual(["m_1", "m_old"])
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR, KEY_VAR])
    expect(e.cleanup.tokenFileRemoved).toBe(true)
    expect(e.cleanup.installRevoked).toBe(true)
    expect(f.removed).toEqual([`${opts.work}/cloud-token`])
    // The token file held the access token (and is gone); the evidence and the log hold no secret.
    expect(f.files.has(`${opts.work}/cloud-token`)).toBe(false)
    expect(f.lines.join("\n")).toContain(`::add-mask::${ACCESS}`)
    const evidence = f.files.get(opts.evidence)!
    for (const s of [EMAIL, PASSWORD, STACK_ACCESS, ACCESS, API_KEY]) {
      expect(evidence).not.toContain(s)
      expect(f.lines.filter((l) => !l.startsWith("::add-mask::")).join("\n")).not.toContain(s)
    }
    expect(f.lines).toContain(`::add-mask::${API_KEY}`)
  })

  test("without the API key the agent part is skipped and the run fails", async () => {
    const f = fakes()
    const e = await runE2E(opts, env(""), f.deps)
    expect(e.agentReply).toBe("skipped (no CMUX_E2E_ANTHROPIC_API_KEY)")
    expect(e.result).toBe("fail")
    expect(e.vaultSet.anthropicKey).toBe("skipped")
    expect(f.lines.some((l) => l.startsWith("::notice::"))).toBe(true)
    expect(f.calls.some((a) => a.includes("run"))).toBe(false)
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR])
  })

  test("an acpmux without the vault capability is refused", async () => {
    const f = fakes({ noCapability: true })
    const e = await runE2E(opts, env(), f.deps)
    expect(e.result).toBe("fail")
    expect(e.acpmuxCapability).toBe(false)
    expect(e.reason).toContain(VAULT_CAPABILITY)
    expect(f.revoked).toContain("m_1")
  })

  test("a wrong reply fails", async () => {
    const e = await runE2E(opts, env(), fakes({ reply: "something else" }).deps)
    expect(e.agentReply).toBe("mismatch")
    expect(e.result).toBe("fail")
  })

  test("the nonce missing from the machine's vault fails", async () => {
    const e = await runE2E(opts, env(), fakes({ vaultEnv: [KEY_VAR] }).deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain(`${NONCE_VAR} is not on the machine`)
  })

  test("an existing ANTHROPIC_API_KEY is neither overwritten nor removed", async () => {
    const f = fakes({ existingKey: true })
    const e = await runE2E(opts, env(), f.deps)
    expect(e.vaultSet.anthropicKey).toBe("kept-existing")
    expect(f.stdins[KEY_VAR]).toBeUndefined()
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR])
  })

  test("a failed join still revokes and removes the vault entries", async () => {
    const f = fakes({ addExit: 1 })
    const e = await runE2E(opts, env(), f.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("machine add: exit 1")
    expect(f.revoked).toContain("m_1")
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR, KEY_VAR])
  })

  test("a secret in a child's output or in the home fails the run", async () => {
    const leaked = await runE2E(opts, env(), fakes({ leak: `oops ${API_KEY}` }).deps)
    expect(leaked.result).toBe("fail")
    expect(leaked.reason).toContain("the output holds a secret value")
    const inHome = await runE2E(opts, env(), fakes({ homeBody: `export ANTHROPIC_API_KEY=${API_KEY}\n` }).deps)
    expect(inHome.result).toBe("fail")
    expect(inHome.reason).toContain("the home holds")
  })

  test("program files' constants are not join tokens; a token in any other file is", async () => {
    // An installed binary: Mach-O magic, the bare prefix and a token-shaped constant.
    const binary = "\xcf\xfa\xed\xfe" + "\0".repeat(28) + "cmj_\0" + "cmj_constantJoinPrefixInTheBinary0123"
    const clean = await runE2E(opts, env(), fakes({ homeFiles: { "./.local/bin/acpmux": binary, "./.local/bin/claude": "\x7fELF" + "cmj_" } }).deps)
    expect(clean.result).toBe("pass")
    expect(clean.secretScan.home.cmj).toBe(0)
    const leaked = await runE2E(opts, env(), fakes({ homeFiles: { "./.acpmux/log.txt": "token cmj_ABCDEFGHIJKLMNOPQRSTUVWXYZ\n" } }).deps)
    expect(leaked.result).toBe("fail")
    expect(leaked.reason).toContain("the home holds a join token")
  })

  test("the archive must be whole: a nonzero exit or any complaint fails", async () => {
    const exit = await runE2E(opts, env(), fakes({ tarExit: 1 }).deps)
    expect(exit.reason).toContain("could not scan the whole disposable home")
    const complaint = await runE2E(opts, env(), fakes({ tarStderr: "tar: ./x: Can't open\n" }).deps)
    expect(complaint.reason).toContain("could not scan the whole disposable home")
  })

  test("refuses another origin, a bad user or name, and missing stack secrets", async () => {
    expect(refusal({ ...opts, origin: "https://example.com" })).toContain("origin")
    expect(refusal({ ...opts, user: "root" })).toContain("user")
    expect(refusal({ ...opts, name: "laptop" })).toContain("name")
    expect(refusal({ ...opts, work: "relative" })).toContain("work")
    expect(refusal(opts)).toBeUndefined()
    await expect(runE2E(opts, { CMUX_UITEST_STACK_EMAIL: EMAIL }, fakes().deps)).rejects.toThrow("must be set")
  })

  test("a cancel while a vault write is in flight waits for it, then removes it", async () => {
    let release: () => void = () => undefined
    const gate = new Promise<void>((resolve) => (release = resolve))
    const f = fakes({ holdSet: { [KEY_VAR]: gate } })
    let cancel: () => Promise<void> = async () => undefined
    const running = runE2E(opts, env(), f.deps, (c) => (cancel = c))
    // Let the flow reach the held ANTHROPIC_API_KEY write.
    for (let i = 0; i < 200 && f.stdins[NONCE_VAR] === undefined; i++) await Bun.sleep(1)
    await Bun.sleep(5)
    const cleaning = cancel()
    await Bun.sleep(5)
    release()
    await cleaning
    const e = await running
    expect(e.result).toBe("fail")
    expect(f.vault.has(KEY_VAR)).toBe(false)
    expect(f.vault.has(NONCE_VAR)).toBe(false)
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR, KEY_VAR])
    // Nothing the main flow would have done next ran: no join.
    expect(f.calls.some((a) => a.includes("add"))).toBe(false)
  })

  test("an existing nonce entry is neither overwritten nor removed", async () => {
    const f = fakes()
    f.vault.add(NONCE_VAR)
    const e = await runE2E(opts, env(), f.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain(`${NONCE_VAR} is already in this account's vault`)
    expect(f.stdins[NONCE_VAR]).toBeUndefined()
    expect(f.vault.has(NONCE_VAR)).toBe(true)
    expect(f.calls.some((a) => a.includes("rm"))).toBe(false)
  })

  test("a killed child whose descendant holds its pipes still answers", async () => {
    const started = Date.now()
    const r = await realDeps().run(["/bin/sh", "-c", "sleep 30 & sleep 30"], { env: { PATH: "/usr/bin:/bin" }, timeoutMs: 50 })
    expect(r.code).toBeNull()
    expect(Date.now() - started).toBeLessThan(3_000)
  })

  test("a failed required cleanup fails the run", async () => {
    const install = await runE2E(opts, env(), fakes({ installRevokeStatus: 500 }).deps)
    expect(install.result).toBe("fail")
    expect(install.cleanup.installRevoked).toBe(false)
    expect(install.reason).toContain("could not revoke the run's cmux install")
    const rm = await runE2E(opts, env(), fakes({ rmFails: true }).deps)
    expect(rm.result).toBe("fail")
    expect(rm.reason).toContain("is still in the vault after cleanup")
  })

  test("the API key is in the vault only from right before the join to right after the reply", async () => {
    const f = fakes()
    const e = await runE2E(opts, env(), f.deps)
    expect(e.result).toBe("pass")
    const at = (pred: (a: string[]) => boolean) => f.calls.findIndex(pred)
    const setKey = at((a) => a.includes("set") && a.includes(KEY_VAR))
    const add = at((a) => a.includes("add"))
    const run = at((a) => a.includes("run"))
    const rmKey = at((a) => a.includes("rm") && a.includes(KEY_VAR))
    expect(setKey).toBe(add - 1)
    expect(rmKey).toBe(run + 1)
    // Cleanup does not remove it again, and still checks the list.
    expect(f.calls.filter((a) => a.includes("rm") && a.includes(KEY_VAR)).length).toBe(1)
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR, KEY_VAR])
  })

  test("cleanup revokes the join's machine by id first, then confirms it on the list", async () => {
    const f = fakes()
    const e = await runE2E(opts, env(), f.deps)
    const machineCalls = f.requests.filter((r) => r.includes("/v1/machines/credentials"))
    expect(machineCalls[0]).toBe(`POST ${DEV_PLATFORM}/v1/machines/credentials/m_1/revoke`)
    expect(machineCalls[1]).toBe(`GET ${DEV_PLATFORM}/v1/machines/credentials`)
    expect(e.cleanup.machinesConfirmed).toBe(true)
    expect(e.cleanup.signedOut).toBe(true)
  })

  test("an unconfirmed machine revoke fails the run", async () => {
    const live = await runE2E(opts, env(), fakes({ revokeNoop: true }).deps)
    expect(live.result).toBe("fail")
    expect(live.cleanup.machinesConfirmed).toBe(false)
    expect(live.reason).toContain("machine m_1 is still live after cleanup")
    const unlisted = await runE2E(opts, env(), fakes({ listStatus: 500 }).deps)
    expect(unlisted.result).toBe("fail")
    expect(unlisted.cleanup.machinesConfirmed).toBe(false)
    expect(unlisted.reason).toContain("machine revoke unconfirmed")
  })

  test("a failed stale-machine revoke or Stack sign-out fails the run", async () => {
    const stale = await runE2E(opts, env(), fakes({ staleRevokeStatus: 500 }).deps)
    expect(stale.result).toBe("fail")
    expect(stale.reason).toContain("revoke m_old (left by an earlier run): HTTP 500")
    const signOut = await runE2E(opts, env(), fakes({ signOutStatus: 500 }).deps)
    expect(signOut.result).toBe("fail")
    expect(signOut.cleanup.signedOut).toBe(false)
    expect(signOut.reason).toContain("could not sign out the run's Stack session")
  })

  test("a cancel with a stalled request still cleans up within the budget, machine and vault first", async () => {
    const f = fakes({ agentHangs: true, stall: ["install.revoke"] })
    let cancel: () => Promise<void> = async () => undefined
    const running = runE2E(opts, env(), f.deps, (c) => (cancel = c))
    for (let i = 0; i < 2_000 && !f.calls.some((a) => a.includes("run")); i++) await Bun.sleep(1)
    const started = Date.now()
    await cancel()
    const took = Date.now() - started
    const e = await running
    expect(took).toBeLessThan(CANCEL_BUDGET_MS)
    expect(e.cleanup.cancelCleanupMs).not.toBeNull()
    expect(e.cleanup.cancelCleanupMs!).toBeLessThan(CANCEL_BUDGET_MS)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("cancelled")
    expect(e.reason).toContain("could not revoke the run's cmux install")
    // The machine and the vault were done before the stalled request.
    expect(f.revoked).toContain("m_1")
    expect(e.cleanup.machinesConfirmed).toBe(true)
    expect(f.vault.size).toBe(0)
    // Earlier runs' machines wait for a run that has the time.
    expect(f.revoked).not.toContain("m_old")
    // The home scan is skipped after a cancel.
    expect(f.calls.some((a) => a.includes("/usr/bin/tar"))).toBe(false)
  }, 15_000)

  test("a cancel during a slow cleanup starts a fresh pass on the deadline", async () => {
    const f = fakes({ firstRmHangs: true, reply: "wrong" })
    let cancel: () => Promise<void> = async () => undefined
    const running = runE2E(opts, env(), f.deps, (c) => (cancel = c))
    // The run fails on its own (a wrong reply); its cleanup hangs on the first vault rm.
    for (let i = 0; i < 2_000 && !f.calls.some((a) => a.includes("rm") && a.includes(NONCE_VAR)); i++) await Bun.sleep(1)
    const started = Date.now()
    await cancel()
    expect(Date.now() - started).toBeLessThan(CANCEL_BUDGET_MS)
    const e = await running
    expect(e.result).toBe("fail")
    expect(f.vault.size).toBe(0)
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR, KEY_VAR])
    expect(e.reason).not.toContain("interrupted")
  }, 15_000)

  test("a cancel during the install revoke leaves no token file, though the fresh pass writes it again", async () => {
    const f = fakes({ reply: "wrong", stall: ["install.revoke"] })
    let cancel: () => Promise<void> = async () => undefined
    const running = runE2E(opts, env(), f.deps, (c) => (cancel = c))
    // The run fails on its own; its cleanup stalls on the install revoke, after the vault (which wrote the token).
    for (let i = 0; i < 2_000 && !f.requests.some((r) => r.includes("install.revoke")); i++) await Bun.sleep(1)
    const writesBefore = f.calls.filter((a) => a[0] === opts.cmux).length
    await cancel()
    const e = await running
    // The fresh pass ran the CLI again (so wrote the token file again), and the file is gone all the same.
    expect(f.calls.filter((a) => a[0] === opts.cmux).length).toBeGreaterThan(writesBefore)
    expect(f.files.has(`${opts.work}/cloud-token`)).toBe(false)
    expect(e.cleanup.tokenFileRemoved).toBe(true)
    expect(e.result).toBe("fail")
  }, 15_000)

  test("cleanup ends by the cancel deadline when requests stall and commands run to their timeouts", async () => {
    const f = fakes({ agentHangs: true, stall: ["/revoke", "install.revoke", "sessions/current"], cleanupCmdsHang: true })
    let cancel: () => Promise<void> = async () => undefined
    const running = runE2E(opts, env(), f.deps, (c) => (cancel = c))
    for (let i = 0; i < 2_000 && !f.calls.some((a) => a.includes("run")); i++) await Bun.sleep(1)
    const started = Date.now()
    await cancel()
    const took = Date.now() - started
    const e = await running
    // No floor past the deadline, and a killed child's grace is inside it.
    expect(took).toBeLessThanOrEqual(CANCEL_BUDGET_MS + 100)
    expect(e.cleanup.cancelCleanupMs!).toBeLessThanOrEqual(CANCEL_BUDGET_MS + 100)
    expect(e.result).toBe("fail")
    expect(f.files.has(`${opts.work}/cloud-token`)).toBe(false)
  }, 20_000)

  test("reads the CLIs' JSON", () => {
    expect(lastJson('noise\n{"a":1}\n{"b":2}\n')).toEqual({ b: 2 })
    expect(lastJson('{\n  "reply": "x"\n}\n')).toEqual({ reply: "x" })
    expect(replyText('{"reply": "  abc\\n"}')).toBe("abc")
    expect(replyText("not json")).toBeNull()
  })
})
