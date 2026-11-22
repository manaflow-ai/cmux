// The live manifest stays valid for today's runtime; the v2 sketch validates
// against the platform v2 schema; catalog fragments are well formed and bind
// every app op to an export of dist/main.js.
import { describe, expect, test } from "bun:test"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { SchemaValidator } from "../../../cmux-tui/crates/cmux-app-host/tools/json-schema.ts"
import { validatePackage } from "../../../cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts"

const dir = join(import.meta.dir, "..")
const host = join(dir, "../../cmux-tui/crates/cmux-app-host")
const json = (p: string) => JSON.parse(readFileSync(p, "utf8"))

describe("manifests", () => {
  test("cmux-app.json is valid", () => {
    expect(validatePackage(dir).errors).toEqual([])
  })

  test("cmux-app.v2.json validates against the v2 schema and agrees with the live manifest", () => {
    const v2 = json(join(dir, "cmux-app.v2.json"))
    expect(new SchemaValidator(json(join(host, "schema/v2/cmux-app.schema.json"))).validate(v2)).toEqual([])
    const v1 = json(join(dir, "cmux-app.json"))
    expect(v2.id).toBe(v1.id)
    expect(Object.keys(v2.scopes)).toEqual(Object.keys(v1.scopes))
    expect(Object.keys(v2.optionalScopes)).toEqual(Object.keys(v1.optionalScopes))
    expect(v2.variants[0].values).toEqual(v1.contributes.settings.properties.variant.enum)
    for (const name of [...Object.keys(v2.implements), ...(v2.consumes ?? [])]) {
      const [iface, major] = name.split("/")
      expect(() => readFileSync(join(host, "interfaces", iface, `${major}.json`))).not.toThrow()
    }
  })

  test("catalog fragments: app ops bind to exports, every op is complete", () => {
    const exportsOf = new Set(Object.keys(json(join(dir, "cmux-app.json")).contributes.commands.reduce((m: Record<string, 1>, c: { run: string }) => ({ ...m, [c.run]: 1 }), {})))
    const app = json(join(dir, `catalog/${json(join(dir, "cmux-app.v2.json")).catalog.split("/").pop()}`))
    expect(app.owner).toBe(`app:${json(join(dir, "cmux-app.json")).id}`)
    for (const o of app.operations) expect(exportsOf.has(o.export)).toBe(true)
    for (const file of readdirSync(join(dir, "catalog")).map((f) => `catalog/${f}`)) {
      for (const o of json(join(dir, file)).operations) {
        for (const key of ["name", "class", "risk", "docs", "input", "owner", "idempotency"]) expect(o[key]).toBeDefined()
        expect(o.idempotency).toBe(o.class === "mutation" ? "required" : "forbidden")
        if (o.risk === "execute") expect(o.origin).toBe("user")
      }
    }
  })
})
