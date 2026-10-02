import { describe, expect, test } from "bun:test"
import { mkdtempSync, readdirSync, readFileSync, writeFileSync, mkdirSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { SchemaValidator } from "../../tools/json-schema.ts"
import { validatePackage } from "../../tools/validate-manifest.ts"
import { generate, scopeFor } from "../../tools/gen-cmux-global.ts"

const root = join(import.meta.dir, "../..")
const schema = new SchemaValidator(JSON.parse(readFileSync(join(root, "schema/cmux-app.schema.json"), "utf8")))
const fixtures = join(root, "schema/fixtures")

describe("manifest schema", () => {
  for (const f of readdirSync(join(fixtures, "valid"))) {
    test(`valid/${f}`, () => expect(schema.validate(JSON.parse(readFileSync(join(fixtures, "valid", f), "utf8")))).toEqual([]))
  }
  for (const f of readdirSync(join(fixtures, "invalid")).filter((f) => !f.endsWith(".expect.json"))) {
    test(`invalid/${f}`, () => {
      const expected = JSON.parse(readFileSync(join(fixtures, "invalid", f.replace(".json", ".expect.json")), "utf8"))
      const errors = schema.validate(JSON.parse(readFileSync(join(fixtures, "invalid", f), "utf8")))
      expect(errors.some((e) => e.path === expected.path && e.code === expected.code)).toBe(true)
    })
  }
})

describe("package validation", () => {
  const pkg = (manifest: object, files: Record<string, string> = {}) => {
    const dir = mkdtempSync(join(tmpdir(), "cmux-app-"))
    writeFileSync(join(dir, "cmux-app.json"), JSON.stringify(manifest))
    for (const [p, c] of Object.entries(files)) {
      mkdirSync(join(dir, p, ".."), { recursive: true })
      writeFileSync(join(dir, p), c)
    }
    return dir
  }
  const base = { manifestVersion: 1, id: "local/x", name: "X", version: "1.0.0", description: "d", engines: { cmux: "^1.0" } }
  test("missing render export is reported", () => {
    const r = validatePackage(pkg({ ...base, main: "dist/main.js", contributes: { sidebarSections: [{ id: "s", title: "S", render: "renderS" }] } }, { "dist/main.js": "globalThis.__cmuxAppExports = { other() {} }" }))
    expect(r.errors.map((e) => e.code)).toContain("export.missing")
  })
  test("duplicate contribution ids are reported", () => {
    const r = validatePackage(pkg({ ...base, main: "m.js", contributes: { sidebarSections: [{ id: "a", title: "A", render: "r" }], commands: [{ id: "a", title: "A", run: "r" }] } }, { "m.js": "var __cmuxAppExports = { r() {} }" }))
    expect(r.errors.map((e) => e.code)).toContain("contribution.duplicate")
  })
  test("publisher must equal the repository owner", () => {
    const r = validatePackage(pkg({ ...base, id: "alice/x", repository: "https://github.com/bob/x" }))
    expect(r.errors.map((e) => e.code)).toContain("publisher.mismatch")
  })
  test("reserved publishers need a manaflow-ai repository", () => {
    const r = validatePackage(pkg({ ...base, id: "cmux/x", repository: "https://github.com/mallory/x" }))
    expect(r.errors.map((e) => e.code)).toContain("publisher.reserved")
  })
  test("files outside `files` are reported", () => {
    const r = validatePackage(pkg({ ...base, main: "src/m.js", files: ["dist/"] }, { "src/m.js": "var __cmuxAppExports = { a() {} }" }))
    expect(r.errors.map((e) => e.code)).toContain("path.notInFiles")
  })
  test("sample apps are valid", () => {
    const samples = join(root, "../../../samples/apps")
    for (const name of ["github-prs", "running-agents", "agent-status"]) {
      const r = validatePackage(join(samples, name))
      expect({ name, errors: r.errors }).toEqual({ name, errors: [] })
    }
  })
})

describe("generator", () => {
  test("deterministic and matches the checked-in files", () => {
    const a = generate()
    expect(generate()).toEqual(a)
    for (const [name, content] of Object.entries(a)) expect(readFileSync(join(root, "generated", name), "utf8")).toBe(content)
  })
  test("scope derivation", () => {
    expect(scopeFor("workspace.list", { class: "read" })).toBe("workspace:read")
    expect(scopeFor("tab.focus", { class: "mutation" })).toBe("workspace:write")
    expect(scopeFor("terminal.input.write", { class: "mutation" })).toBe("terminal:execute")
    expect(scopeFor("terminal.close", { class: "mutation" })).toBeNull()
    expect(scopeFor("install.revoke", { class: "mutation", risk: "destructive" })).toBeNull()
    expect(scopeFor("team.directory", { class: "read", risk: "read" })).toBe("team:read")
  })
})
