import { describe, expect, test } from "bun:test"
import { mkdtempSync, readdirSync, readFileSync, writeFileSync, mkdirSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { SchemaValidator } from "../../tools/json-schema.ts"
import { checkPalette, validatePackage } from "../../tools/validate-manifest.ts"
import { buildOps, generate, NEVER_OPS, paramsTypeOf, scopeFor } from "../../tools/gen-cmux-global.ts"
import { loadAppCatalogs, schemaType } from "../../tools/app-catalogs.ts"

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
    for (const name of ["github-prs", "running-agents", "agent-status", "palette-notes"]) {
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
  test("money, person-only and named ops are never reachable from apps", () => {
    // Money: the backend risk, and app catalog ops that move money.
    expect(scopeFor("usage.cap.set", { class: "mutation", risk: "money" })).toBeNull()
    // Person-only: a backend op a signed-in person may call but no install (the
    // device that runs apps) may.
    expect(scopeFor("integration.connect", { class: "mutation", risk: "mutate-own", principals: ["session"] })).toBeNull()
    expect(scopeFor("automation.list", { class: "read", risk: "read", principals: ["session", "install"] })).toBe("automation:read")
    // Named: cloud.machine.link_token mints dial tokens, whatever its risk.
    expect(NEVER_OPS.has("cloud.machine.link_token")).toBe(true)
    expect(scopeFor("cloud.machine.link_token", { class: "mutation", risk: "execute" })).toBeNull()
    const files = generate()
    const scopes = JSON.parse(files["scopes.json"]!)
    expect(scopes.ops["cloud.billing.checkout"]).toBeUndefined()
    expect(scopes.never).toContain("cloud.billing.checkout")
    expect(scopes.ops["integration.connect"]).toBeUndefined()
    expect(scopes.never).toContain("integration.connect")
  })
  test("consumed backend ops are typed and scoped from the serving fragment", () => {
    const backend = {
      "cloud.machine.list": { class: "read", risk: "read", principals: ["session", "install"], docs: "backend", input_json_schema: {}, output_json_schema: {} },
      "cloud.machine.link_token": { class: "mutation", risk: "execute", principals: ["session", "install"], docs: "mints a dial token" },
      "cloud.usage.cap": { class: "mutation", risk: "money", principals: ["session", "install"], docs: "spends" },
    }
    const served = (consumes: string[], extra: object[] = []) => ({
      app: "cloud",
      consumes,
      operations: [
        { name: "cloud.machine.list", owner: "app:cmux/cloud", class: "read", risk: "read", docs: "from the server", input: { type: "object", properties: { team: { type: "string" } } }, output: { type: "array", items: { type: "string" } } },
        ...extra,
      ],
    })
    const ops = buildOps({}, backend, [served(["cloud.machine.list"])])
    expect(ops["cloud.machine.list"]).toMatchObject({ source: "app", owner: "app:cmux/cloud", docs: "from the server" })
    expect(paramsTypeOf(ops["cloud.machine.list"]!)).toBe("{ team?: string }")
    // A consumed op that apps may never reach is refused, by name or by risk.
    const linkToken = { name: "cloud.machine.link_token", owner: "app:cmux/cloud", class: "mutation", risk: "mutate-own", docs: "x", input: { type: "object" } }
    expect(() => buildOps({}, backend, [served(["cloud.machine.link_token"], [linkToken])])).toThrow(/never/)
    const cap = { name: "cloud.usage.cap", owner: "app:cmux/cloud", class: "mutation", risk: "mutate-own", docs: "x", input: { type: "object" } }
    expect(() => buildOps({}, backend, [served(["cloud.usage.cap"], [cap])])).toThrow(/never/)
    // One server per op; a consumed op must be a backend op the fragment declares.
    expect(() => buildOps({}, backend, [served(["cloud.machine.list"]), { ...served(["cloud.machine.list"]), app: "other" }])).toThrow(/already/)
    expect(() => buildOps({}, backend, [served(["cloud.nope"])])).toThrow(/not a backend op/)
    expect(() => buildOps({}, backend, [{ app: "cloud", consumes: ["cloud.machine.list"], operations: [] }])).toThrow(/declare/)
    // Without consumes, a fragment op that a backend op already owns is refused.
    expect(() => buildOps({}, backend, [served([])])).toThrow(/already owns/)
  })
  test("first-party app catalog ops get scopes and typed clients", () => {
    const files = generate()
    const scopes = JSON.parse(files["scopes.json"]!).ops
    expect(scopes["rd.session.start"]).toEqual({ scope: "rd:execute", class: "mutation" })
    expect(scopes["rd.session.list"]).toEqual({ scope: "rd:read", class: "read" })
    expect(JSON.parse(files["ops.json"]!).ops).toContain("rd.session.start")
    expect(files["cmux-app.d.ts"]).toContain("owner `app:cmux/remote-desktop`")
    expect(files["cmux-app.d.ts"]).toContain('start: CmuxOp<{ host: string; target?: string; mode?: "view" | "control" }, { session: string; tab: string }>')
  })
  test("app catalog fragments are validated", () => {
    const dir = mkdtempSync(join(tmpdir(), "cmux-app-catalogs-"))
    mkdirSync(join(dir, "bad/catalog"), { recursive: true })
    writeFileSync(join(dir, "bad/cmux-app.v2.json"), JSON.stringify({ catalog: "catalog/c.json" }))
    writeFileSync(join(dir, "bad/catalog/c.json"), JSON.stringify({ family: "bad", operations: [{ name: "bad.x" }] }))
    expect(() => loadAppCatalogs(dir)).toThrow(/bad\/catalog\/c.json/)
  })
  test("JSON Schema to TypeScript", () => {
    expect(schemaType({ type: "object", properties: { a: { type: "integer" }, b: { type: "array", items: { enum: ["x", "y"] } } }, required: ["a"] }))
      .toBe('{ a: number; b?: Array<"x" | "y"> }')
    expect(schemaType({ type: "object", additionalProperties: false })).toBe("Record<string, never>")
    expect(schemaType({ oneOf: [{ type: "string" }, { type: "null" }] })).toBe("string | null")
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
