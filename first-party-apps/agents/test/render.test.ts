import { describe, expect, test } from "bun:test"
import { callsOf, makeHost, tap, texts, visible } from "./harness.ts"

const M = "m1"

async function mount(fixture: string, exportName: string, settings: Record<string, unknown> = {}, overrides: Record<string, unknown> = {}) {
  const host = makeHost(fixture, settings, overrides)
  expect(host.mount(M, exportName, {})).toBe("")
  await host.settle(20)
  return host
}

describe("variants", () => {
  for (const variant of ["byCli", "byMachine", "matrix"]) {
    test(`${variant}: lists machines and versions, summary counts updates and sign-ins`, async () => {
      const host = await mount(variant, "renderPane", { variant })
      const t = texts(host, M)
      expect(t).toContain("5 updates · 2 need sign-in")
      expect(t.some((s) => s.includes("build-server"))).toBe(true)
      expect(t.some((s) => s.includes("Claude Code"))).toBe(true)
      // One agent_cli.list per machine, each scoped to its machine.
      expect(callsOf(host, "agent_cli.list").map((c) => c.params.machine)).toEqual(["machine_mac01", "machine_srv01", "machine_vm01"])
      // No email-like text ever renders.
      expect(t.join(" ")).not.toMatch(/[^\s@]+@[^\s@]+\.[a-z]/)
    })
  }

  test("byCli: badge is the largest pending update across machines", async () => {
    const host = await mount("byCli", "renderPane", { variant: "byCli" })
    expect(texts(host, M)).toContain("Major")
  })

  test("matrix: tapping a cell shows its details", async () => {
    const host = await mount("matrix", "renderPane", { variant: "matrix" })
    await tap(host, M, "0.148.0")
    expect(texts(host, M)).toContain("Codex on build-server")
    expect(texts(host, M)).toContain("Installed with npm")
  })

  test("byMachine: missing CLIs are folded and show install hints when opened", async () => {
    const host = await mount("byMachine", "renderPane", { variant: "byMachine" })
    expect(texts(host, M)).toContain("Not installed (4)")
    expect(texts(host, M)).not.toContain("npm install -g @google/gemini-cli")
    await tap(host, M, "Not installed (4)")
    expect(texts(host, M)).toContain("npm install -g @google/gemini-cli")
  })

  test("showMissing=false hides CLIs installed nowhere", async () => {
    const host = await mount("byCli", "renderPane", { variant: "byCli", showMissing: false })
    expect(texts(host, M)).not.toContain("Gemini CLI")
  })
})

describe("actions", () => {
  test("Update asks the host with the gesture and shows the running job until the watch reports the end", async () => {
    const host = await mount("localOnly", "renderPane", { variant: "byMachine" })
    await tap(host, M, "Update")
    const [call] = callsOf(host, "agent_cli.update")
    expect(call!.params).toMatchObject({ machine: "machine_mac01", cli: "claude" })
    expect(call!.options.gesture).toBe("gst_test")
    expect(texts(host, M)).toContain("Updating in a terminal…")
    host.emit("agent_cli.watch", { machine: "machine_mac01", cli: "claude", job: { job: "job_01", ok: true }, entry: { cli: "claude", installed: true, version: "2.1.290", latest: { version: "2.1.290" }, install_method: "native", updatable: true, accounts: [{ account: "acct_c1", label: "Work", plan: "Max", status: "signed_in" }] } })
    await host.settle(10)
    expect(texts(host, M)).toContain("2.1.290, up to date")
    expect(texts(host, M)).not.toContain("Updating in a terminal…")
  })

  test("a refused update says which permission is missing and offers Try Again", async () => {
    const host = await mount("refused", "renderPane", { variant: "byMachine" })
    await tap(host, M, "Update")
    expect(texts(host, M)).toContain("Allow this app to run commands in Settings > Apps")
    expect(texts(host, M)).toContain("Try Again")
  })

  test("Sign In falls back to the accounts action on this Mac when agent_cli.sign_in is missing", async () => {
    const host = await mount("localOnly", "renderPane", { variant: "byMachine" }, { "agent_cli.sign_in": { $error: { code: "operation.unsupported", message: "" } }, "action.run": {} })
    await tap(host, M, "Sign In…")
    const [run] = callsOf(host, "action.run")
    expect(run!.params).toEqual({ id: "accounts.reauthenticate", args: { provider: "codex" } })
    expect(run!.options.gesture).toBe("gst_test")
  })

  test("Install sends the first hint's method for the machine's platform", async () => {
    const host = await mount("byMachine", "renderPane", { variant: "byMachine" })
    await tap(host, M, "Not installed (4)")
    await tap(host, M, "Install…")
    expect(callsOf(host, "agent_cli.install")[0]!.params).toMatchObject({ machine: "machine_mac01", cli: "gemini", method: "npm" })
  })
})

describe("section and states", () => {
  test("section: this machine's installed CLIs with an Update badge", async () => {
    const host = await mount("localOnly", "renderSection")
    const t = texts(host, M)
    expect(t).toContain("Claude Code")
    expect(t).toContain("4 more you can install")
    const badges = visible(host, M).filter(([, n]) => n.type === "Row").map(([, n]) => n.props.badge ?? null)
    expect(badges).toEqual(["Update", "Update", null, null, null])
  })
  test("empty, error and missing op", async () => {
    expect(texts(await mount("empty", "renderSection"), M)).toContain("No agent CLIs on this machine")
    expect(texts(await mount("error", "renderPane"), M)).toContain("Cannot list agent CLIs")
    expect(texts(await mount("missing", "renderPane"), M)).toContain("Agent CLI detection is not available yet")
  })
  test("no machine.list: the app still lists the current machine", async () => {
    const host = await mount("localOnly", "renderPane", { variant: "byMachine" }, { "machine.list": { $error: { code: "operation.unsupported", message: "" } } })
    expect(texts(host, M)).toContain("This Mac")
    expect(callsOf(host, "agent_cli.list")[0]!.params.machine).toBeUndefined()
  })
  test("cycleVariant walks the three designs", async () => {
    const host = await mount("byCli", "renderPane", {}, { "app.settings.set": {} })
    host.global.__cmuxAppRunCommand("cycleVariant", "{}", 1)
    await host.settle(5)
    expect(host.commandResults.get(1)?.body.value.variant).toBe("byMachine")
  })
})

