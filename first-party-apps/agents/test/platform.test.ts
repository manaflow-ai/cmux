import { describe, expect, test } from "bun:test"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { pack } from "../../../cmux-tui/crates/cmux-app-host/tools/pack.ts"
import { hintsFor, platformOf } from "../src/model/providers.ts"
import type { Machine } from "../src/model/entries.ts"

const source = await pack(join(import.meta.dir, ".."))
const ok = (value: unknown) => ({ ok: true, body: { value } })

async function shown(metadata: Partial<Machine>): Promise<string> {
  const host = new FakeHost(source, {
    app: { id: "cmux/agents", version: "0.1.0", locale: "en" }, apiVersion: "1.0.0",
    settings: { variant: "byCli", showMissing: true }
  })
  host.handlers = {
    "machine.list": () => ok([{ id: "remote", name: "server", origin: "server", status: "running", ...metadata }]),
    "agent_cli.list": () => ok({ machine: "remote", clis: [], complete: true })
  }
  host.mount("pane", "renderPane", { locale: "en" })
  await host.settle()
  expect(host.logs.filter(([level]) => level === "error")).toEqual([])
  return JSON.stringify([...host.tree("pane").nodes.values()])
}

describe("machine-specific install hints", () => {
  test("unidentified and unsupported platforms do not become macOS", () => {
    for (const os of [null, undefined, "", "windows", "freebsd", "linux-ish", "darwin-ish"]) {
      expect(platformOf(os)).toBeNull()
      expect(hintsFor("codex", platformOf(os))).toEqual([])
    }
  })

  test("recognized owner platforms retain their existing hints", () => {
    for (const os of ["darwin", "macos", "macOS"]) {
      expect(platformOf(os)).toBe("darwin")
      expect(hintsFor("codex", platformOf(os)).some((hint) => hint.method === "brew")).toBe(true)
    }
    expect(platformOf("Linux")).toBe("linux")
    expect(hintsFor("codex", platformOf("Linux")).some((hint) => hint.method === "brew")).toBe(false)
  })

  test("a nested Linux platform overrides legacy macOS and offers no Homebrew hints", async () => {
    const text = await shown({ platform: { os: "linux", arch: "aarch64" }, os: "darwin" })
    expect(text).toContain("npm install -g @openai/codex")
    expect(text).not.toContain("brew install")
    expect(text).toContain("Install…")
  })

  test("unknown servers have no install command or Install action", async () => {
    for (const metadata of [{}, { platform: { os: "windows" }, os: "darwin" }]) {
      const text = await shown(metadata)
      expect(text).toContain("No install hint for this CLI")
      expect(text).not.toContain("Install…")
      expect(text).not.toContain("brew install")
      expect(text).not.toContain("npm install")
      expect(text).not.toContain("curl ")
    }
  })

  test("legacy OS fields remain usable when no structured platform exists", async () => {
    const linux = await shown({ os: "linux" })
    expect(linux).toContain("npm install -g @openai/codex")
    expect(linux).not.toContain("brew install")
    expect(await shown({ platform: { os: "macos" } })).toContain("brew install --cask codex")
  })
})
