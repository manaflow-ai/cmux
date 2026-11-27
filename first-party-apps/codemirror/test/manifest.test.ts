// The manifest: a web pane with the editor interface, no network, built files present, packages credited.
import { describe, expect, test } from "bun:test"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"

const appDir = join(import.meta.dir, "..")
const manifest = JSON.parse(readFileSync(join(appDir, "cmux-app.json"), "utf8"))

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
