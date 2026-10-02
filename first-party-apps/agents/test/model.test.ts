import { describe, expect, test } from "bun:test"
import { applyWatch, type CliEntry, highestLevel, needsSignIn, safeLabel, showsAccounts, sortEntries, statusOf, summarize, withMissing } from "../src/model/entries.ts"
import { busy, type Job, reduceJob } from "../src/model/jobs.ts"
import { displayName, hintsFor, platformOf, PROVIDERS, providerFor } from "../src/model/providers.ts"
import { compareVersions, parseVersion, shortVersion, updateLevel } from "../src/model/version.ts"

const entry = (cli: string, version: string | null, latest: string | null, extra: Partial<CliEntry> = {}): CliEntry => ({
  cli,
  installed: version !== null,
  version,
  latest: latest ? { version: latest } : null,
  install_method: "npm",
  updatable: true,
  accounts: [{ account: "a", label: "Work", status: "signed_in" }],
  ...extra
})

describe("provider table", () => {
  test("ids are unique, every entry has a binary and a hint, names are not empty", () => {
    expect(new Set(PROVIDERS.map((p) => p.id)).size).toBe(PROVIDERS.length)
    for (const p of PROVIDERS) {
      expect(p.binaries.length).toBeGreaterThan(0)
      expect(p.hints.length).toBeGreaterThan(0)
      expect(p.name.length).toBeGreaterThan(0)
    }
  })
  test("the CLIs the hub must know are in the table", () => {
    for (const id of ["claude", "codex", "opencode", "pi", "chief"]) expect(providerFor(id)).not.toBeNull()
  })
  test("accounts provider ids match the existing accounts action's providers", () => {
    const known = new Set(["codex", "openai", "claude", "anthropic", "gemini", "openrouter", "groq", "xai", "mistral", "deepseek", "bedrock", "vertex", "copilot"])
    for (const p of PROVIDERS) if (p.accountsProvider) expect(known.has(p.accountsProvider)).toBe(true)
  })
  test("brew hints only on macOS; unknown ids get no hint and keep the owner name", () => {
    expect(hintsFor("codex", "darwin").map((h) => h.method)).toEqual(["npm", "brew"])
    expect(hintsFor("codex", "linux").map((h) => h.method)).toEqual(["npm"])
    expect(hintsFor("mystery", "darwin")).toEqual([])
    expect(displayName("mystery", "Mystery Agent")).toBe("Mystery Agent")
    expect(displayName("mystery")).toBe("mystery")
    expect(platformOf("Linux 6.8")).toBe("linux")
    expect(platformOf(null)).toBe("darwin")
  })
  test("no install hint pipes a URL that is not https", () => {
    for (const p of PROVIDERS) for (const h of p.hints) if (h.command.includes("curl")) expect(h.command).toMatch(/https:\/\//)
  })
})

describe("versions", () => {
  test("parses what CLIs print", () => {
    expect(parseVersion("2.1.281 (Claude Code)")?.text).toBe("2.1.281")
    expect(parseVersion("codex-cli 0.149.1")?.text).toBe("0.149.1")
    expect(parseVersion("v1.2.3-beta.2")?.text).toBe("1.2.3-beta.2")
    expect(parseVersion("opencode version 2026.09.30")?.nums).toEqual([2026, 9, 30])
    expect(parseVersion("no version")).toBeNull()
    expect(parseVersion("")).toBeNull()
    expect(shortVersion("codex-cli 0.149.1")).toBe("0.149.1")
    expect(shortVersion("dev build")).toBe("dev build")
  })
  test("orders numbers, not text", () => {
    expect(compareVersions("0.10.0", "0.9.9")).toBe(1)
    expect(compareVersions("1.2", "1.2.0")).toBe(0)
    expect(compareVersions("2.1.281", "2.1.290")).toBe(-1)
    expect(compareVersions("x", "1.0.0")).toBeNull()
  })
  test("semver prerelease precedence", () => {
    const ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
    for (let i = 0; i + 1 < ordered.length; i++) expect(compareVersions(ordered[i], ordered[i + 1])).toBe(-1)
  })
  test("update level", () => {
    expect(updateLevel("2.1.281", "2.1.290")).toBe("patch")
    expect(updateLevel("0.149.1", "0.150.0")).toBe("minor")
    expect(updateLevel("2.1.250", "3.0.0-beta.1")).toBe("major")
    expect(updateLevel("1.2.3", "1.2.3")).toBe("none")
    expect(updateLevel("1.3.0", "1.2.9")).toBe("newer")
    expect(updateLevel("1.2.3", null)).toBe("unknown")
  })
})

describe("entries", () => {
  test("status per entry", () => {
    expect(statusOf(entry("claude", "2.1.281", "2.1.290"))).toBe("update")
    expect(statusOf(entry("claude", "2.1.290", "2.1.290"))).toBe("current")
    expect(statusOf(entry("claude", "2.2.0", "2.1.290"))).toBe("ahead")
    expect(statusOf(entry("claude", "2.1.0", null))).toBe("unknown")
    expect(statusOf(entry("claude", null, "2.1.0"))).toBe("missing")
  })
  test("the owner reports installed CLIs; table CLIs it did not report are missing, sorted after", () => {
    const list = withMissing([entry("codex", "0.1.0", "0.1.0"), entry("mystery", "1.0.0", null)])
    expect(list.slice(0, 2).map((e) => e.cli)).toEqual(["codex", "mystery"])
    expect(list.filter((e) => !e.installed).map((e) => e.cli)).toEqual(PROVIDERS.filter((p) => p.id !== "codex").map((p) => p.id))
  })
  test("watch: update replaces, removal turns a table CLI back into missing, new CLIs are added in order", () => {
    let list = withMissing([entry("codex", "0.1.0", "0.2.0")])
    list = applyWatch(list, { machine: "m", cli: "codex", entry: entry("codex", "0.2.0", "0.2.0") })
    expect(statusOf(list.find((e) => e.cli === "codex")!)).toBe("current")
    list = applyWatch(list, { machine: "m", cli: "claude", entry: entry("claude", "2.0.0", "2.0.0") })
    expect(list[0]!.cli).toBe("claude")
    list = applyWatch(list, { machine: "m", cli: "claude", removed: true })
    expect(list.find((e) => e.cli === "claude")?.installed).toBe(false)
    expect(sortEntries(list)).toEqual(list)
  })
  test("sign-in: expired or signed-out accounts; cmux-managed CLIs never ask", () => {
    expect(needsSignIn(entry("codex", "1.0.0", null, { accounts: [{ account: "a", label: "x", status: "expired" }] }))).toBe(true)
    expect(needsSignIn(entry("codex", "1.0.0", null, { accounts: [] }))).toBe(true)
    expect(needsSignIn(entry("chief", "1.0.0", null, { accounts: [] }))).toBe(false)
    expect(showsAccounts(entry("chief", "1.0.0", null, { accounts: [] }))).toBe(false)
    expect(needsSignIn(entry("mystery", "1.0.0", null, { accounts: [] }))).toBe(false)
    expect(needsSignIn(entry("codex", null, null, { accounts: [] }))).toBe(false)
  })
  test("summary and highest level across machines", () => {
    const a = [entry("claude", "2.1.281", "2.1.290"), entry("codex", "1.0.0", "1.0.0", { accounts: [] })]
    const b = [entry("claude", "1.0.0", "2.1.290")]
    expect(summarize([a, b])).toEqual({ updates: 2, missingSignIns: 1, installed: 3 })
    expect(highestLevel([a[0], b[0], null])).toBe("major")
    expect(highestLevel([a[1]])).toBeNull()
  })
  test("labels never show an email or a token", () => {
    expect(safeLabel("Work")).toBe("Work")
    expect(safeLabel("someone@example.com")).toBe("s…@…")
    expect(safeLabel(`key ${"Ab3".repeat(12)}`)).toBe("key …")
    expect(safeLabel(null)).toBe("")
  })
})

describe("host-run jobs", () => {
  const request = reduceJob(null, { type: "request", kind: "update" })!
  test("request -> started -> finished", () => {
    const running = reduceJob(request, { type: "started", job: "job_1", terminal: "terminal_1" })!
    expect(running.phase).toBe("running")
    expect(busy(running)).toBe(true)
    const done = reduceJob(running, { type: "finished", job: "job_1", ok: true })!
    expect(done.phase).toBe("succeeded")
    expect(reduceJob(done, { type: "clear" })).toBeNull()
  })
  test("a second tap while busy is ignored, a stale finish is ignored, clear keeps a running job", () => {
    const running = reduceJob(request, { type: "started", job: "job_1", terminal: null })!
    expect(reduceJob(running, { type: "request", kind: "install" })).toBe(running)
    expect(reduceJob(running, { type: "finished", job: "job_0", ok: false })).toBe(running)
    expect(reduceJob(running, { type: "clear" })).toBe(running)
  })
  test("refusal and failure can be retried", () => {
    const refused = reduceJob(request, { type: "refused", error: "scope.missing" })!
    expect(refused.phase).toBe("refused")
    expect(reduceJob(refused, { type: "request", kind: "update" })!.phase).toBe("requested")
    const running = reduceJob(request, { type: "started", job: "j", terminal: null })!
    const failed: Job = reduceJob(running, { type: "finished", job: "j", ok: false, exitCode: 1 })!
    expect(failed.exitCode).toBe(1)
    expect(reduceJob(failed, { type: "request", kind: "update" })!.phase).toBe("requested")
  })
  test("events out of order do nothing", () => {
    expect(reduceJob(null, { type: "started", job: "j", terminal: null })).toBeNull()
    expect(reduceJob(null, { type: "finished", job: "j", ok: true })).toBeNull()
    expect(reduceJob(reduceJob(request, { type: "refused", error: "x" }), { type: "started", job: "j", terminal: null })!.phase).toBe("refused")
  })
})
