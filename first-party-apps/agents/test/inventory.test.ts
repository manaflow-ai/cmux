import { describe, expect, test } from "bun:test"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { pack } from "../../../cmux-tui/crates/cmux-app-host/tools/pack.ts"
import { applyWatch, highestLevel, needsSignIn, showsAccounts, statusOf, summarize, withMissing, type CliEntry } from "../src/model/entries.ts"

const source = await pack(join(import.meta.dir, ".."))
const observed = (patch: Partial<CliEntry> = {}): CliEntry => ({
  cli: "codex", installed: true, version: "1.0.0", latest: { version: "1.0.0" },
  install_method: "npm", updatable: true, accounts: [], ...patch
})

describe("cached inventory evidence", () => {
  test("only explicit completeness permits synthesizing missing installs", () => {
    expect(withMissing([], false)).toEqual([])
    expect(withMissing([])).toEqual([])
    expect(withMissing([], "true" as unknown as boolean)).toEqual([])
    expect(withMissing([], true).length).toBeGreaterThan(0)
    expect(withMissing([], true).every((e) => e.installed === false)).toBe(true)
  })

  test("an unverified launcher cannot be promoted to installed or missing", () => {
    const launcher = observed({ installed: null, latest: { version: "2.0.0" } })
    expect(statusOf(launcher)).toBe("unknown")
    expect(highestLevel([launcher])).toBeNull()
    expect(needsSignIn(launcher)).toBe(false)
    expect(showsAccounts(launcher)).toBe(false)
    expect(summarize([[launcher]]).unknown).toBe(1)
  })

  test("no account observations is not evidence of being signed out", () => {
    expect(needsSignIn(observed())).toBe(false)
    expect(needsSignIn(observed({ auth_status: "unknown" }))).toBe(false)
    expect(needsSignIn(observed({ auth_status: "missing" }))).toBe(true)
  })

  test("removing a partial observation cannot manufacture missing providers", () => {
    expect(applyWatch([observed()], { machine: "remote", cli: "codex", removed: true }, false)).toEqual([])
    expect(applyWatch([observed()], { machine: "remote", cli: "codex", removed: true }, true)
      .find((e) => e.cli === "codex")?.installed).toBe(false)
  })
})

const ok = (value: unknown) => ({ ok: true, body: { value } })
const machines = [
  { id: "local", name: "local", origin: "local", status: "running" },
  { id: "remote", name: "remote", origin: "server", status: "running" }
]

async function mount(variant: string, inventories: Record<string, unknown>, language = "en") {
  const host = new FakeHost(source, {
    app: { id: "cmux/agents", version: "0.1.0", locale: language }, apiVersion: "1.0.0",
    settings: { variant, showMissing: true }
  })
  host.handlers = {
    "machine.list": () => ok(machines.filter((m) => m.id in inventories)),
    "agent_cli.list": ({ machine }) => ok({ machine, ...inventories[machine] as object })
  }
  host.mount("pane", "renderPane", { locale: language })
  host.mount("section", "renderSection", { locale: language })
  await host.settle()
  return host
}

const shown = (host: FakeHost, mount = "pane") => JSON.stringify([...host.tree(mount).nodes.values()])

describe("inventory views", () => {
  for (const variant of ["byCli", "byMachine", "matrix"]) {
    test(`${variant}: a partial empty cache offers no installation or absence claim`, async () => {
      const host = await mount(variant, { local: { clis: [], complete: false } })
      for (const mount of ["pane", "section"]) {
        const text = shown(host, mount)
        expect(text).toContain("Inventory not fully checked")
        expect(text).not.toContain("No agent CLIs found")
        expect(text).not.toContain("No agent CLIs on this machine")
        expect(text).not.toContain("Not installed")
        expect(text).not.toContain("Install…")
      }
      expect(host.logs.filter(([level]) => level === "error")).toEqual([])
    })

    test(`${variant}: an unobserved remote cell remains unknown`, async () => {
      const host = await mount(variant, {
        local: { clis: [observed({ auth_status: "signed_in" })], complete: true },
        remote: { clis: [], complete: false }
      })
      const text = shown(host)
      expect(text).toContain("Inventory not fully checked")
      expect(text).not.toContain("Not on remote")
      expect(text).not.toContain("Signed out")
      expect(host.logs.filter(([level]) => level === "error")).toEqual([])
    })

    test(`${variant}: launcher observations stay visible without actions`, async () => {
      const host = await mount(variant, { local: { clis: [observed({ installed: null, version: null, latest: null })], complete: false } })
      const text = shown(host)
      expect(text).toContain("Installation unknown")
      expect(text).not.toContain("Not installed")
      expect(text).not.toContain("Install…")
      expect(text).not.toContain("Signed out")
    })
  }

  test("an invalidated partial empty cache preserves the unknown inventory state", async () => {
    const inventories = { local: { clis: [observed()], complete: false } }
    const host = await mount("byMachine", inventories)
    inventories.local = { clis: [], complete: false }
    host.emit("agent_cli.changed", {})
    await host.settle()
    expect(shown(host)).toContain("Inventory not fully checked")
    expect(shown(host)).not.toContain("Not installed")
    expect(shown(host)).not.toContain("Install…")
  })

  test("a complete empty inventory retains explicit missing rows", async () => {
    const host = await mount("byMachine", { local: { clis: [], complete: true } })
    expect(shown(host)).toContain("Not installed")
    expect(shown(host, "section")).toContain("No agent CLIs on this machine")
  })

  test("Japanese shows the same distinction", async () => {
    const host = await mount("byMachine", { local: { clis: [], complete: false } }, "ja")
    expect(shown(host)).toContain("インストール状況は未確認です")
    expect(shown(host, "section")).not.toContain("このマシンにエージェントCLIはありません")
  })
})
