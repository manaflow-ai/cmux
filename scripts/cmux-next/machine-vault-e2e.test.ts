import { describe, expect, test } from "bun:test"
import {
  CANCEL_BUDGET_MS,
  KILL_GRACE_MS,
  DEV_API,
  DEV_PLATFORM,
  AGENT_SCRIPT,
  STUB_SCRIPT,
  agentScript,
  stubTurns,
  LOGIN_VAR,
  NONCE_VAR,
  PLACEHOLDER,
  PROMPT,
  ALLOWED_HOST,
  EGRESS_CAPABILITY,
  VAULT_CAPABILITY,
  type ChildResult,
  type Deps,
  type Options,
  lastJson,
  realDeps,
  refusal,
  replyPasses,
  replyText,
  runE2E
} from "./machine-vault-e2e.ts"

// Fake values shaped like the real ones; none is a real credential.
const EMAIL = "ci-account@example.invalid"
const PASSWORD = "fake-password-value"
const STACK_ACCESS = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJzdGFjay11c2VyIn0.c3RhY2tzaWduYXR1cmU"
const ACCESS = "eyJhbGciOiJFUzI1NiIsImtpZCI6ImsxIn0.eyJzdWIiOiJ1c2VyXzEifQ.YWNjZXNzc2lnbmF0dXJl"
const LOGIN = "sk-ant-oat01-FAKEloginVALUEfor-tests-0123456789"
const NONCE = "0123456789abcdef0123456789abcdef"
const HOME = "/Users/cmuxvault11"
const GOOD = `env=${PLACEHOLDER}\nallowed=${NONCE}\ndenied=${PLACEHOLDER}\nHello from a vault test run.`

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
  envDelivery?: boolean
  reply?: string
  addExit?: number
  /** pgrep's exit for the user's acpmux and claude processes after cleanup (1: none left). */
  holdersExit?: number
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
  const vault = new Set<string>()
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
      if (argv[0] === opts.ssh) {
        stdins.ssh = stdin ?? ""
        if (k.agentHangs) {
          await aborted(signal)
          return { code: null, stdout: "", stderr: "" }
        }
        return ok(JSON.stringify({ sessionId: "s", name: "n", reply: k.reply ?? `${GOOD}\n`, stopReason: "end_turn" }, null, 2))
      }
      if (argv[0] === "/usr/bin/pgrep") return { code: k.holdersExit ?? 1, stdout: "", stderr: "" }
      if (argv[0] === "sudo") {
        if (text.includes("/bin/kill")) return ok()
        if (text.endsWith("acpmux capabilities")) return ok(k.noCapability ? "machine.join.stdin.v1\n" : `machine.join.stdin.v1\n${VAULT_CAPABILITY}\n${EGRESS_CAPABILITY}\n`)
        if (text.includes("machine vault status")) {
          return ok(JSON.stringify({ joined: true, secretStore: "keychain", lastResult: "ok", env: (k.vaultEnv ?? [NONCE_VAR]).map((name) => ({ name, revision: 1, delivery: k.envDelivery ? "env" : "proxy" })) }, null, 2))
        }
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

const env = (login = LOGIN) => ({ CMUX_UITEST_STACK_EMAIL: EMAIL, CMUX_UITEST_STACK_PASSWORD: PASSWORD, CLAUDE_CODE_OAUTH_TOKEN: login })
const isAgent = (a: string[]) => a[0] === opts.ssh

describe("machine-vault-e2e", () => {
  test("on the model stub: a made-up login, Claude Code pointed at the stub, every model request carried that login", async () => {
    const f = fakes()
    let log = ""
    f.deps.readFile = (path) => (path === "/tmp/stub.jsonl" ? log : "")
    const run = f.deps.run
    f.deps.run = async (argv, o) => {
      if (argv[0] === opts.ssh) {
        const sha = new Bun.CryptoHasher("sha256").update((o.stdin ?? "").trim()).digest("hex")
        log = [1, 2, 3, 4].map((step) => JSON.stringify({ protocol: "anthropic", method: "POST", path: "/v1/messages", stream: true, step, cred_sha256: sha })).join("\n") + "\n"
      }
      return run(argv, o)
    }
    const e = await runE2E(opts, { ...env(""), MODEL_STUB_URL: "http://127.0.0.1:18123", MODEL_STUB_LOG: "/tmp/stub.jsonl" }, f.deps)
    expect(e.result).toBe("pass")
    expect(e.reason).toContain("on the model stub")
    expect(e.model).toEqual({ mode: "stub", requests: 4, loginMatched: true })
    expect(f.stdins.ssh).toMatch(/^sk-ant-oat01-vaultstub-[0-9a-f]+\n$/)
    const agent = f.calls.find(isAgent)!
    expect(agent[3]).toBe(agentScript("http://127.0.0.1:18123"))
    expect(agent[3]).toContain("ANTHROPIC_BASE_URL")
    expect(agent[3]).toContain("http://127.0.0.1:18123")
    expect(AGENT_SCRIPT).not.toContain("ANTHROPIC_BASE_URL")
  })

  test("on the model stub: a model request with another login fails the run", async () => {
    const f = fakes()
    f.deps.readFile = () => JSON.stringify({ protocol: "anthropic", method: "POST", path: "/v1/messages", cred_sha256: "0".repeat(64) }) + "\n"
    const e = await runE2E(opts, { ...env(""), MODEL_STUB_URL: "http://127.0.0.1:18123", MODEL_STUB_LOG: "/tmp/stub.jsonl" }, f.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("did not carry the login")
    expect(e.model.loginMatched).toBe(false)
  })

  test("the stub address must be loopback, and the stub's script is the prompt's three commands", () => {
    expect(() => agentScript("http://evil.example:80")).toThrow()
    expect(() => agentScript("http://127.0.0.1:1; rm -rf ~")).toThrow()
    expect(stubTurns('{"protocol":"anthropic","method":"POST","path":"/v1/messages","cred_sha256":"a"}\nnot json\n{"protocol":"anthropic","method":"POST","path":"/v1/messages/count_tokens"}\n')).toHaveLength(1)
    const script = JSON.parse(require("node:fs").readFileSync(require("node:path").join(import.meta.dir, "../..", STUB_SCRIPT), "utf8"))
    const shells = script.steps.filter((s: any) => s.shell).map((s: any) => s.shell)
    for (const piece of [`printenv ${NONCE_VAR}`, `https://${ALLOWED_HOST}/headers`, "https://httpbin.org/headers"]) expect(shells.join("\n")).toContain(piece)
  })

  test("passes when the subscription-signed-in agent replies with the nonce, and cleans up", async () => {
    const f = fakes()
    const e = await runE2E(opts, env(), f.deps)
    expect(e.reason).toBe("vault set, joined over ssh, vault on the machine, the agent signed in with the subscription saw only the placeholder, the allowed host got the value and the other host the placeholder, cleaned up, no secrets found")
    expect(e.result).toBe("pass")
    expect(e.agentResult).toBe("pass")
    expect(e.agentReply).toBe(GOOD)
    expect(e.claudeLogin).toEqual({ delivery: "ssh-stdin", daemonRestarted: true })
    expect(e.nonce).toBe(NONCE)
    // Values go on stdin, never argv: the nonce to the vault, the login to the ssh session alone.
    expect(f.stdins[NONCE_VAR]).toBe(`${NONCE}\n`)
    // The nonce is proxy-delivered and allowed to the one echo host.
    const set = f.calls.find((a) => a.includes("set"))!
    expect(set.slice(set.indexOf("set") + 1, set.indexOf("set") + 4)).toEqual([NONCE_VAR, "--host", ALLOWED_HOST])
    expect(f.stdins.ssh).toBe(`${LOGIN}\n`)
    for (const argv of f.calls) expect(argv.join(" ")).not.toContain(LOGIN)
    // The login never enters the vault.
    expect(f.calls.some((a) => a.includes(LOGIN_VAR) && a.includes("vault"))).toBe(false)
    expect(Object.keys(f.stdins).sort()).toEqual([NONCE_VAR, "ssh"])
    // The one command.
    const add = f.calls.find((a) => a.includes("add"))!
    expect(add.slice(1, 8)).toEqual(["--json", "machine", "add", "--vault", "--yes", "--name", opts.name])
    expect(add).toContain(`${opts.user}@localhost`)
    // The agent: one ssh session to the user, the script its only argument.
    const run = f.calls.find(isAgent)!
    expect(run).toEqual([opts.ssh, "--", `${opts.user}@localhost`, AGENT_SCRIPT])
    expect(AGENT_SCRIPT).toContain(`'${PROMPT}'`)
    expect(AGENT_SCRIPT).toContain("-m claude")
    // This run's machine and the stale CI one, never another machine.
    expect(f.revoked.sort()).toEqual(["m_1", "m_old"])
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR])
    expect(e.cleanup.loginHoldersStopped).toBe(true)
    expect(e.secretScan.home.login).toBe(0)
    expect(e.secretScan.log.login).toBe(0)
    expect(e.cleanup.tokenFileRemoved).toBe(true)
    expect(e.cleanup.installRevoked).toBe(true)
    expect(f.removed).toEqual([`${opts.work}/cloud-token`])
    // The token file held the access token (and is gone); the evidence and the log hold no secret.
    expect(f.files.has(`${opts.work}/cloud-token`)).toBe(false)
    expect(f.lines.join("\n")).toContain(`::add-mask::${ACCESS}`)
    const evidence = f.files.get(opts.evidence)!
    for (const s of [EMAIL, PASSWORD, STACK_ACCESS, ACCESS, LOGIN]) {
      expect(evidence).not.toContain(s)
      expect(f.lines.filter((l) => !l.startsWith("::add-mask::")).join("\n")).not.toContain(s)
    }
    expect(f.lines).toContain(`::add-mask::${LOGIN}`)
    // The mask comes before anything else is printed.
    expect(f.lines.findIndex((l) => l === `::add-mask::${LOGIN}`)).toBeLessThan(f.lines.findIndex((l) => !l.startsWith("::add-mask::")))
  })

  test("without the Claude login the agent part is skipped and the run fails", async () => {
    const f = fakes()
    const e = await runE2E(opts, env(""), f.deps)
    expect(e.agentResult).toBe("skipped (no CLAUDE_CODE_OAUTH_TOKEN)")
    expect(e.agentReply).toBeNull()
    expect(e.result).toBe("fail")
    expect(f.lines.some((l) => l.startsWith("::notice::"))).toBe(true)
    expect(f.calls.some(isAgent)).toBe(false)
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR])
    expect(e.secretScan.log.login).toBeNull()
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
    expect(e.agentResult).toBe("mismatch")
    expect(e.agentReply).toBe("something else")
    expect(e.result).toBe("fail")
    // The three values alone, with no sentence of the model's own, are not a real reply.
    const bare = await runE2E(opts, env(), fakes({ reply: `env=${PLACEHOLDER}\nallowed=${NONCE}\ndenied=${PLACEHOLDER}` }).deps)
    expect(bare.agentResult).toBe("mismatch")
  })

  test("the reply must show the placeholder in the env, the nonce at the allowed host only, and a sentence", () => {
    const ok = (env: string, allowed: string, denied: string, rest = "Hi there, all good here.") =>
      replyPasses(`env=${env}\nallowed=${allowed}\ndenied=${denied}\n${rest}`, NONCE)
    expect(ok(PLACEHOLDER, NONCE, PLACEHOLDER)).toBe(true)
    expect(replyPasses(`\`env=${PLACEHOLDER}\`\n\`allowed=${NONCE}\`\n\`denied=${PLACEHOLDER}\`\n\nHello from Claude Code today.`, NONCE)).toBe(true)
    expect(ok(PLACEHOLDER, NONCE, PLACEHOLDER, "")).toBe(false)
    // The agent saw the value: the old env delivery.
    expect(ok(NONCE, NONCE, NONCE)).toBe(false)
    // The value reached the host it does not allow.
    expect(ok(PLACEHOLDER, NONCE, NONCE)).toBe(false)
    // The proxy did not put the value in for the allowed host.
    expect(ok(PLACEHOLDER, PLACEHOLDER, PLACEHOLDER)).toBe(false)
    expect(ok(PLACEHOLDER, "other", PLACEHOLDER)).toBe(false)
  })

  test("the nonce on env delivery, or an acpmux without the egress proxy, fails", async () => {
    const env1 = await runE2E(opts, env(), fakes({ envDelivery: true }).deps)
    expect(env1.result).toBe("fail")
    expect(env1.reason).toContain(`${NONCE_VAR} is not delivered through the proxy`)
  })

  test("a process still holding the login after cleanup fails the run", async () => {
    const e = await runE2E(opts, env(), fakes({ holdersExit: 0 }).deps)
    expect(e.result).toBe("fail")
    expect(e.cleanup.loginHoldersStopped).toBe(false)
    expect(e.reason).toContain("a process that held the Claude login is still running after cleanup")
  }, 15_000)

  test("the nonce missing from the machine's vault fails", async () => {
    const e = await runE2E(opts, env(), fakes({ vaultEnv: ["OTHER"] }).deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain(`${NONCE_VAR} is not on the machine`)
  })

  test("a failed join still revokes and removes the vault entries", async () => {
    const f = fakes({ addExit: 1 })
    const e = await runE2E(opts, env(), f.deps)
    expect(e.result).toBe("fail")
    expect(e.reason).toContain("machine add: exit 1")
    expect(f.revoked).toContain("m_1")
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR])
  })

  test("a secret in a child's output or in the home fails the run", async () => {
    const leaked = await runE2E(opts, env(), fakes({ leak: `oops ${LOGIN}` }).deps)
    expect(leaked.result).toBe("fail")
    expect(leaked.reason).toContain("the output holds the Claude login")
    expect(leaked.secretScan.log.login).toBeGreaterThan(0)
    const inHome = await runE2E(opts, env(), fakes({ homeBody: `export CLAUDE_CODE_OAUTH_TOKEN=${LOGIN}\n` }).deps)
    expect(inHome.result).toBe("fail")
    expect(inHome.reason).toContain("the home holds the Claude login")
    expect(inHome.secretScan.home.login).toBe(1)
    expect(inHome.secretScan.home.files).toEqual(["./.zshenv"])
    // A file name that is itself a secret is redacted.
    const nf = fakes({ homeFiles: { [`./${LOGIN}`]: "x" } })
    await runE2E(opts, env(), nf.deps)
    // The written evidence keeps the redacted path (it is not the redaction-failure stub).
    const written = JSON.parse(nf.files.get(opts.evidence) ?? "{}")
    expect(written.secretScan.home.files).toEqual(["./[secret]"])
  })

  test("a reply in the login's shape is never written as evidence", async () => {
    const f = fakes({ reply: `env=${PLACEHOLDER}\nallowed=${NONCE}\ndenied=${PLACEHOLDER}\nsk-ant-oat01-something else here` })
    const e = await runE2E(opts, env(), f.deps)
    expect(e.result).toBe("fail")
    expect(f.files.get(opts.evidence)).not.toContain("sk-ant-")
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
    const f = fakes({ holdSet: { [NONCE_VAR]: gate } })
    let cancel: () => Promise<void> = async () => undefined
    const running = runE2E(opts, env(), f.deps, (c) => (cancel = c))
    // Let the flow reach the held nonce write.
    for (let i = 0; i < 200 && !f.calls.some((a) => a.includes("set")); i++) await Bun.sleep(1)
    await Bun.sleep(5)
    const cleaning = cancel()
    await Bun.sleep(5)
    release()
    await cleaning
    const e = await running
    expect(e.result).toBe("fail")
    expect(f.vault.has(NONCE_VAR)).toBe(false)
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR])
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
    for (let i = 0; i < 2_000 && !f.calls.some(isAgent); i++) await Bun.sleep(1)
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
    expect(e.cleanup.vaultRemoved).toEqual([NONCE_VAR])
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
    for (let i = 0; i < 2_000 && !f.calls.some(isAgent); i++) await Bun.sleep(1)
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
