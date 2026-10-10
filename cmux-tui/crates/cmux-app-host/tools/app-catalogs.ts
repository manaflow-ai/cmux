// First-party app catalog fragments (manifest v2 `catalog`) for the generator:
// every first-party-apps/<name>/cmux-app.v2.json that names a catalog, each
// fragment validated with schema/v2/cmux-app-catalog.schema.json (the same
// schema the Rust validator embeds). Ops carry JSON Schema input/output, which
// `schemaType` turns into TypeScript.

import { existsSync, readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { SchemaValidator } from "./json-schema.ts"

export interface AppCatalogOp {
  name: string
  owner: string
  class: string
  risk: string
  docs: string
  input: Record<string, unknown>
  output?: Record<string, unknown>
}

/** One first-party app's catalog fragment. */
export interface AppFragment {
  /** The first-party-apps directory name. */
  app: string
  /** Backend ops this app's server serves (D-ROUTE); typed and scoped from this fragment. */
  consumes: string[]
  operations: AppCatalogOp[]
}

const here = new URL(".", import.meta.url).pathname
const catalogSchema = JSON.parse(readFileSync(join(here, "../schema/v2/cmux-app-catalog.schema.json"), "utf8"))

/** Every first-party app's catalog ops, sorted by app; throws on an invalid fragment. */
export function loadAppCatalogs(firstPartyDir: string): AppCatalogOp[] {
  return loadAppFragments(firstPartyDir).flatMap((fragment) => fragment.operations)
}

/** Every first-party app's catalog fragment, sorted by app; throws on an invalid fragment. */
export function loadAppFragments(firstPartyDir: string): AppFragment[] {
  const validator = new SchemaValidator(catalogSchema)
  const out: AppFragment[] = []
  for (const name of readdirSync(firstPartyDir).sort()) {
    const manifestPath = join(firstPartyDir, name, "cmux-app.v2.json")
    if (!existsSync(manifestPath)) continue
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as { catalog?: string }
    if (!manifest.catalog) continue
    const fragment = JSON.parse(readFileSync(join(firstPartyDir, name, manifest.catalog), "utf8"))
    const errors = validator.validate(fragment)
    if (errors.length) throw new Error(`first-party-apps/${name}/${manifest.catalog}: ${errors.map((e) => `${e.path} ${e.message}`).join("; ")}`)
    out.push({ app: name, consumes: (fragment.consumes ?? []) as string[], operations: fragment.operations as AppCatalogOp[] })
  }
  return out
}

const ident = (s: string) => (/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(s) ? s : JSON.stringify(s))

/** TypeScript for the JSON Schema subset catalog ops use. */
export function schemaType(schema: unknown, depth = 0): string {
  if (!schema || typeof schema !== "object" || depth > 8) return "unknown"
  const s = schema as Record<string, unknown>
  if (Array.isArray(s.enum)) return s.enum.map((v) => JSON.stringify(v)).join(" | ") || "never"
  if ("const" in s) return JSON.stringify(s.const)
  for (const key of ["oneOf", "anyOf"]) if (Array.isArray(s[key])) return (s[key] as unknown[]).map((b) => schemaType(b, depth + 1)).join(" | ")
  const type = Array.isArray(s.type) ? (s.type as string[]) : [s.type as string | undefined]
  const parts = type.map((t) => {
    switch (t) {
      case "string": return "string"
      case "integer": case "number": return "number"
      case "boolean": return "boolean"
      case "null": return "null"
      case "array": return `Array<${schemaType(s.items, depth + 1)}>`
      case "object": {
        const props = Object.entries((s.properties ?? {}) as Record<string, unknown>)
        const required = new Set((s.required ?? []) as string[])
        if (!props.length) return s.additionalProperties === false ? "Record<string, never>" : "Record<string, unknown>"
        return `{ ${props.map(([k, v]) => `${ident(k)}${required.has(k) ? "" : "?"}: ${schemaType(v, depth + 1)}`).join("; ")} }`
      }
      default: return "unknown"
    }
  })
  return parts.join(" | ")
}
