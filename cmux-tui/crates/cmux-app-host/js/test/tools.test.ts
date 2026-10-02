import { describe, expect, test } from "bun:test"
import { mkdtempSync, readdirSync, readFileSync, writeFileSync, mkdirSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { SchemaValidator } from "../../tools/json-schema.ts"
import { checkPalette, validatePackage } from "../../tools/validate-manifest.ts"
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

// Palette fixtures live in fixtures/palette/ until the Swift manifest validator
// (CmuxNextApps) knows contributes.paletteScopes; sync-app-runtime.sh copies only
// fixtures/{valid,invalid}. They run the schema plus the manifest-level palette rules.
describe("palette manifest fixtures", () => {
  const dir = join(fixtures, "palette")
  const check = (manifest: Record<string, unknown>) => {
    const errors = schema.validate(manifest)
    return errors.length ? errors : checkPalette(manifest).errors
  }
  for (const f of readdirSync(join(dir, "valid"))) {
    test(`palette/valid/${f}`, () => expect(check(JSON.parse(readFileSync(join(dir, "valid", f), "utf8")))).toEqual([]))
  }
  for (const f of readdirSync(join(dir, "invalid")).filter((f) => !f.endsWith(".expect.json"))) {
    test(`palette/invalid/${f}`, () => {
      const expected = JSON.parse(readFileSync(join(dir, "invalid", f.replace(".json", ".expect.json")), "utf8"))
      const errors = check(JSON.parse(readFileSync(join(dir, "invalid", f), "utf8")))
      expect(errors.map((e) => `${e.path} ${e.code}`)).toContain(`${expected.path} ${expected.code}`)
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
  const paletteManifest = (source: Record<string, unknown>, detail?: Record<string, unknown>) => ({
    ...base,
    main: "m.js",
    contributes: { paletteScopes: [{ id: "notes", title: "Notes", source, ...(detail ? { detail } : {}) }] }
  })
  test("palette source and detail exports must exist in main", () => {
    const r = validatePackage(pkg(paletteManifest({ kind: "snapshot", export: "corpus" }, { export: "noteDetail" }), { "m.js": "var __cmuxAppExports = { other: palette.snapshot(() => []) }" }))
    expect(r.errors.map((e) => `${e.path} ${e.code}`)).toEqual(["/contributes/paletteScopes/0/source/export export.missing", "/contributes/paletteScopes/0/detail/export export.missing"])
  })
  test("a palette export of the wrong kind is reported", () => {
    const r = validatePackage(pkg(paletteManifest({ kind: "query", export: "corpus" }), { "m.js": "var __cmuxAppExports = { corpus: palette.snapshot(() => [act('a.b', {})]) }" }))
    expect(r.errors.map((e) => e.code)).toEqual(["export.kind"])
  })
  test("an op source outside the catalog is a warning", () => {
    const r = validatePackage(pkg({ ...base, contributes: { paletteScopes: [{ id: "notes", title: "Notes", source: { kind: "op", op: "note.search", item: { id: "$.id", title: "$.t" } } }] } }))
    expect(r.ok).toBe(true)
    expect(r.warnings.map((e) => e.code)).toContain("op.unknown")
  })
  test("sample apps are valid", () => {
    const samples = join(root, "../../../samples/apps")
    // github-prs, running-agents and agent-status are manifest v2 (validated by
    // the Rust crate cmux-app-manifest); palette-notes is still v1.
    for (const name of ["palette-notes"]) {
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

describe("native code tiers", () => {
  const dir = (manifest: object) => {
    const d = mkdtempSync(join(tmpdir(), "cmux-app-native-"))
    writeFileSync(join(d, "cmux-app.json"), JSON.stringify(manifest))
    return d
  }
  const base = { manifestVersion: 1, version: "1.0.0", name: "N", description: "d", engines: { cmux: "^1.0" } }
  test("third-party native server and native pane are refused", () => {
    const r = validatePackage(dir({ ...base, id: "octo/n", repository: "https://github.com/octo/n", server: { kind: "native", binary: "x", hosts: ["local"] }, contributes: { paneKinds: [{ id: "p", title: "P", renderer: "native", nativeView: "x.view" }] } }))
    expect(r.errors.filter((e) => e.code === "tier.native").map((e) => e.path)).toEqual(["/server/kind", "/contributes/paneKinds/0/renderer"])
  })
  test("first-party native server is accepted", () => {
    const d = dir({ ...base, id: "cmux/tasks", repository: "https://github.com/manaflow-ai/cmux", server: { kind: "native", binary: "cmux-tasks", args: ["serve"], hosts: ["team-vm", "local"], data: "durable" }, contributes: { paneKinds: [{ id: "board", title: "Tasks", renderer: "native", nativeView: "tasks.board" }] } })
    expect(validatePackage(d).errors).toEqual([])
  })
})
