/** compat.ts: the cmux-old compatibility gate (contract diffs, inventory at a release tag, receipts). */
import { describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { catalogProblems, changeKey, compatProblems, inventoryHits, openapiProblems, parseChange, supersetProblems } from "../compat.ts"
import { writeReceipt } from "../receipts.ts"
import { TREES } from "../trees.ts"
import { addMigration, REAL, tempRoot } from "./helpers.ts"

const op = (fields: Record<string, { required: boolean }>, result: unknown = { kind: "ref", name: "Thing" }) => ({ class: "query", params: { selectors: {}, fields: Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, { ...v, type: { kind: "primitive", name: "string" } }])) }, result })
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const catalog = (extra: Record<string, unknown> = {}): any => ({
  errors: { "auth.forbidden": { status: 403 }, "thing.missing": { status: 404 } },
  types: { Thing: { kind: "object", fields: { id: { type: { kind: "primitive", name: "string" } }, state: { type: { kind: "enum", values: ["on", "off"] } } } } },
  operations: { "thing.get": op({ id: { required: true }, verbose: { required: false } }) },
  ...extra,
})

describe("backend catalog contract diff", () => {
  it("passes additive changes: a new operation, field, optional param, enum value and error", () => {
    const head = catalog()
    head.errors["thing.busy"] = { status: 409 }
    ;(head.types.Thing.fields as Record<string, unknown>).label = { type: { kind: "primitive", name: "string" } }
    ;(head.types.Thing.fields.state.type as { values: Array<string> }).values.push("paused")
    head.operations["thing.list"] = op({})
    head.operations["thing.get"] = op({ id: { required: true }, verbose: { required: false }, trace: { required: false } })
    expect(catalogProblems(catalog(), head)).toEqual([])
  })
  const breaking: Array<[string, (c: any) => void, string]> = [
    ["a removed operation", (c) => delete (c.operations as Record<string, unknown>)["thing.get"], "operations.thing.get: removed"],
    ["a removed param", (c) => (c.operations["thing.get"] = op({ id: { required: true } })), "params.verbose: removed"],
    ["a newly required param", (c) => (c.operations["thing.get"] = op({ id: { required: true }, verbose: { required: true } })), "params.verbose: newly required"],
    ["a new required param", (c) => (c.operations["thing.get"] = op({ id: { required: true }, verbose: { required: false }, team: { required: true } })), "params.team: newly required"],
    ["a removed error code", (c) => delete (c.errors as Record<string, unknown>)["thing.missing"], "errors.thing.missing: removed"],
    ["a removed enum value", (c) => ((c.types.Thing.fields.state.type as { values: Array<string> }).values = ["on"]), '"off" removed'],
    ["a removed field", (c) => delete (c.types.Thing.fields as Record<string, unknown>).id, "types.Thing.fields.id: removed"],
    ["a renamed result type", (c) => (c.operations["thing.get"] = op({ id: { required: true }, verbose: { required: false } }, { kind: "ref", name: "Thing2" })), 'result.name: "Thing" became "Thing2"'],
  ]
  for (const [what, mutate, expected] of breaking) {
    it(`refuses ${what}`, () => {
      const head = catalog()
      mutate(head)
      expect(catalogProblems(catalog(), head).join("\n")).toContain(expected)
    })
  }
  it("the committed catalog is compatible with itself", () => {
    const doc = JSON.parse(readFileSync(REAL("backend/catalog/cloud-operations.json"), "utf8"))
    expect(catalogProblems(doc, doc)).toEqual([])
  })
  it("ignores documentation-only keys", () => {
    expect(supersetProblems({ a: { description: "x", docs: "y", kind: "k" } }, { a: { kind: "k" } }, "t")).toEqual([])
  })
})

describe("cmux-vm openapi contract diff (pinned oasdiff)", () => {
  const doc = JSON.parse(readFileSync(REAL("workers/cmux-vm/openapi.json"), "utf8"))
  it("refuses a removed endpoint and passes an unchanged document", () => {
    const head = structuredClone(doc)
    const first = Object.keys(head.paths)[0]!
    delete head.paths[first]
    expect(openapiProblems(JSON.stringify(doc), JSON.stringify(head)).join()).toContain("openapi:")
    expect(openapiProblems(JSON.stringify(doc), JSON.stringify(doc))).toEqual([])
  })
})

describe("inventory at the release tag", () => {
  it("finds a host in shipped code and ignores tests and docs", () => {
    const repo = mkdtempSync(join(tmpdir(), "compat-inv-"))
    const git = (...args: Array<string>) => execFileSync("git", ["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", ...args], { encoding: "utf8" })
    git("init", "-q")
    mkdirSync(join(repo, "CLI"), { recursive: true })
    mkdirSync(join(repo, "Packages/X/Tests/XTests"), { recursive: true })
    writeFileSync(join(repo, "CLI/cloud.swift"), 'let api = "https://cmux.com/api/vm"\n')
    writeFileSync(join(repo, "Packages/X/Tests/XTests/T.swift"), 'let x = "https://vm.cmux.dev"\n')
    writeFileSync(join(repo, "README.md"), "vm.cmux.dev\n")
    git("add", ".")
    git("commit", "-qm", "r1")
    git("tag", "v9.0.0")
    expect(inventoryHits(repo, "v9.0.0", ["vm.cmux.dev"])).toEqual([])
    writeFileSync(join(repo, "CLI/cloud.swift"), 'let api = "https://vm.cmux.dev/v1"\n')
    git("commit", "-qam", "r2")
    git("tag", "v9.1.0")
    expect(inventoryHits(repo, "v9.1.0", ["vm.cmux.dev", "cloud-api.cmux.dev"])).toEqual(["vm.cmux.dev in CLI/cloud.swift"])
  })
})

describe("compat receipts gate production", () => {
  it("needs a passing static AND smoke receipt of the same change key in the last 24 h", () => {
    const dir = mkdtempSync(join(tmpdir(), "compat-receipts-"))
    const key = "image:CLOUD_FREESTYLE_SNAPSHOT:sh-x"
    const now = Date.parse("2026-10-09T12:00:00Z")
    const at = (h: number) => new Date(now - h * 3600_000).toISOString()
    expect(compatProblems(dir, key, "production", now).length).toBe(2)
    writeReceipt(dir, { action: "compat-static", tree: "images", target: "production", result: "pass", at: at(1), setHash: key, by: "t" })
    expect(compatProblems(dir, key, "production", now)).toEqual([expect.stringContaining("client smoke")])
    writeReceipt(dir, { action: "compat-smoke", tree: "images", target: "production", result: "pass", at: at(30), setHash: key, by: "t" })
    expect(compatProblems(dir, key, "production", now).length).toBe(1) // too old
    writeReceipt(dir, { action: "compat-smoke", tree: "images", target: "production", result: "pass", at: at(2), setHash: "image:CLOUD_FREESTYLE_SNAPSHOT:sh-other", by: "t" })
    expect(compatProblems(dir, key, "production", now).length).toBe(1) // another change
    writeReceipt(dir, { action: "compat-smoke", tree: "images", target: "production", result: "pass", at: at(2), setHash: key, by: "t" })
    expect(compatProblems(dir, key, "production", now)).toEqual([])
    writeReceipt(dir, { action: "compat-smoke", tree: "images", target: "production", result: "fail", at: at(1), setHash: key, by: "t" })
    expect(compatProblems(dir, key, "production", now).length).toBe(1) // the newest smoke failed
  })
  it("a migration change key moves with every file of the tree", () => {
    const root = tempRoot()
    const before = changeKey(root, parseChange("migrations:cmux-vm"))
    expect(changeKey(root, { kind: "migrations", tree: TREES["cmux-vm"] })).toBe(before)
    addMigration(root, "cmux-vm", "0009_x.sql", "CREATE TABLE cmux_vm.x (id text);\n")
    expect(changeKey(root, parseChange("migrations:cmux-vm"))).not.toBe(before)
    expect(() => parseChange("image:OTHER_VAR:sh-1")).toThrow()
  })
})
