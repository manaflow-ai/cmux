// The app's script (dist/main.js): palette, CLI and MCP commands. Same file in both editor apps.
import { describe, expect, test } from "bun:test"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { EDITOR_VARIANTS } from "../src/shared/chrome.ts"
import { FALLBACK_THEME, syntaxColors, chromeColors } from "../src/shared/theme.ts"

const appDir = join(import.meta.dir, "..")
const manifest = JSON.parse(readFileSync(join(appDir, "cmux-app.json"), "utf8"))
const rev = { counter: 3, hash: "h3" }

function makeHost(settings: Record<string, unknown> = {}) {
  const host = new FakeHost(readFileSync(join(appDir, "dist/main.js"), "utf8"), { app: { id: manifest.id, version: manifest.version }, apiVersion: "1.0.0", settings })
  return host
}

async function run(host: FakeHost, name: string, args: Record<string, unknown> = {}) {
  const cb = Math.floor(Math.random() * 1e9)
  host.global.__cmuxAppRunCommand(name, JSON.stringify(args), cb)
  await host.settle(20)
  return host.commandResults.get(cb)!
}

describe(`${manifest.id} commands`, () => {
  test("open a URI: the owner opens it, the shell opens an editor pane with the handle", async () => {
    const host = makeHost()
    host.handlers["document.open"] = () => ({ ok: true, body: { value: { info: { doc: "doc_9", revision: rev, dirty: false }, text: "" } } })
    host.handlers["app.pane.open"] = () => ({ ok: true, body: { value: { pane: "pane_1" } } })
    const r = await run(host, "open", { uri: "file://m/x.ts" })
    expect(r.body.value).toEqual({ doc: "doc_9" })
    expect(host.calls.map((c) => [c.name, c.params.uri ?? c.params.props])).toEqual([["document.open", "file://m/x.ts"], ["app.pane.open", { doc: "doc_9" }]])
    expect((await run(host, "open", {})).body.code).toBe("invalid_params")
  })

  test("save with a handle saves the owner's current revision; without one it goes to the focused pane", async () => {
    const host = makeHost()
    host.handlers["document.open"] = () => ({ ok: true, body: { value: { info: { doc: "doc_9", revision: rev, dirty: true }, text: "" } } })
    host.handlers["document.save"] = () => ({ ok: true, body: { value: { revision: rev, dirty: false } } })
    host.handlers["app.pane.command"] = (p) => ({ ok: true, body: { value: { ran: p.command } } })
    expect((await run(host, "save", { doc: "doc_9" })).body.value).toEqual({ doc: "doc_9", saved: true })
    expect(host.calls.find((c) => c.name === "document.save")!.params).toMatchObject({ doc: "doc_9", revision: rev })
    expect((await run(host, "save")).body.value).toEqual({ ran: "save" })
    expect((await run(host, "toggleReadOnly")).body.value).toEqual({ ran: "toggleReadOnly" })
  })

  test("missing ops reach the caller as errors with their code", async () => {
    const host = makeHost()
    const r = await run(host, "revert")
    expect(r.ok).toBe(false)
  })

  test("cycleVariant walks every variant", async () => {
    const host = makeHost({ variant: "bare" })
    expect((await run(host, "cycleVariant")).body.value).toEqual({ variant: "statusLine", persisted: false })
    expect(EDITOR_VARIANTS).toEqual(manifest.contributes.settings.properties.variant.enum)
  })
})

describe("manifest", () => {
  test("web pane with the editor interface, no network, built files present", () => {
    const pane = manifest.contributes.paneKinds[0]
    expect(pane.web).toBe("web/index.html")
    expect(pane["x-cmux-implements"].interface).toBe("cmux.editor/1")
    expect(pane["x-cmux-implements"].capabilities).toContain("diff")
    expect(pane.csp.startsWith("default-src 'self'")).toBe(true)
    const html = readFileSync(join(appDir, "web/index.html"), "utf8")
    expect(html).toContain(`content="${pane.csp}"`)
    expect(html).not.toMatch(/https?:\/\//)
    const built = readdirSync(join(appDir, "web"))
    expect(built).toEqual(expect.arrayContaining(["index.html", "main.js", "main.css", "THIRD_PARTY_NOTICES.txt"]))
    for (const f of built.filter((f) => f.endsWith(".js") || f.endsWith(".css"))) expect(readFileSync(join(appDir, "web", f), "utf8")).not.toMatch(/(?:src|href)=["']https?:|@import\s+url\(["']?https?:/)
  })

  test("every bundled package is pinned and credited", () => {
    const pkg = JSON.parse(readFileSync(join(appDir, "package.json"), "utf8"))
    const notices = readFileSync(join(appDir, "THIRD_PARTY_NOTICES"), "utf8")
    for (const [name, version] of Object.entries(pkg.dependencies as Record<string, string>)) {
      expect(version).toMatch(/^\d+\.\d+\.\d+$/)
      expect(notices).toContain(`${name} ${version}`)
    }
  })
})

describe("theme", () => {
  const light = { ...FALLBACK_THEME, appearance: "light" as const, background: "#fafafa", foreground: "#383a42", selectionBackground: "#dcdcdc", cursor: "#383a42", accent: "#a626a4" }
  test("syntax colors never use the blue palette entries; selection, cursor and accent are the host's", () => {
    for (const theme of [FALLBACK_THEME, light]) {
      const blues = [theme.palette[4], theme.palette[12]]
      for (const color of Object.values(syntaxColors(theme))) expect(blues).not.toContain(color)
      const c = chromeColors(theme)
      expect([c.selection, c.cursor, c.accent]).toEqual([theme.selectionBackground, theme.cursor, theme.accent])
      for (const color of Object.values(c)) if (typeof color === "string") expect(blues).not.toContain(color.slice(0, 7))
    }
  })
})
