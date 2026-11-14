#!/usr/bin/env bun
// Builds (or with --check verifies) every example extension's dist/main.js and validates its
// manifest v2 (cmux-app.v2.json, or cmux-app.json for an SDK extension whose dist/ is gitignored and
// so is packed fresh) and catalog against the platform schemas, and that every export
// they name exists. The Rust validator checks the same packages (cmux-app-manifest tests/samples.rs).
// Usage: bun examples/extensions/build.ts [--check]
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"
import { SchemaValidator } from "../../cmux-tui/crates/cmux-app-host/tools/json-schema.ts"

const here = new URL(".", import.meta.url).pathname
const host = join(here, "../../cmux-tui/crates/cmux-app-host")
const check = process.argv.includes("--check")
const read = (p: string) => JSON.parse(readFileSync(p, "utf8"))
const manifestSchema = new SchemaValidator(read(join(host, "schema/v2/cmux-app.schema.json")))
const catalogSchema = new SchemaValidator(read(join(host, "schema/v2/cmux-app-catalog.schema.json")))

let failed = false
const fail = (dir: string, message: string) => {
  console.error(`${dir}: ${message}`)
  failed = true
}
for (const name of readdirSync(here).filter((n) => statSync(join(here, n)).isDirectory()).sort()) {
  const dir = join(here, name)
  // A recipe with a committed dist/ names its manifest cmux-app.v2.json; an extension built on
  // cmux-extension-sdk names it cmux-app.json (what `cmux ext dev` reads) and gitignores dist/,
  // which is build output: here it is packed fresh, then checked like the others.
  const v2 = join(dir, "cmux-app.v2.json")
  const manifestFile = existsSync(v2) ? "cmux-app.v2.json" : existsSync(join(dir, "cmux-app.json")) ? "cmux-app.json" : null
  if (!manifestFile) continue
  const manifestPath = join(dir, manifestFile)
  const built = existsSync(join(dir, ".gitignore")) && readFileSync(join(dir, ".gitignore"), "utf8").split("\n").some((l) => l.trim() === "dist/")
  const pack = Bun.spawnSync(["bun", join(host, "tools/pack.ts"), dir, ...(check && !built ? ["--check"] : [])], { stdout: "inherit", stderr: "inherit" })
  if (pack.exitCode !== 0) failed = true
  const manifest = read(manifestPath)
  for (const e of manifestSchema.validate(manifest)) fail(name, `${manifestFile} ${e.path || "/"} ${e.message}`)
  const main = existsSync(join(dir, "dist/main.js")) ? readFileSync(join(dir, "dist/main.js"), "utf8") : ""
  // A recipe exports functions; an SDK extension may export `const renderX = section(...)`.
  const defines = (fn: string) => main.includes(`function ${fn}(`) || (built && main.includes(`var ${fn} = `))
  for (const [iface, impl] of Object.entries((manifest.implements ?? {}) as Record<string, { export?: string }>)) {
    if (impl.export && !defines(impl.export)) fail(name, `${iface} names ${impl.export}, which dist/main.js does not define`)
  }
  if (typeof manifest.catalog === "string") {
    const catalog = read(join(dir, manifest.catalog))
    for (const e of catalogSchema.validate(catalog)) fail(name, `${manifest.catalog} ${e.path || "/"} ${e.message}`)
    for (const op of catalog.operations ?? []) if (op.export && !defines(op.export)) fail(name, `${op.name} names ${op.export}, which dist/main.js does not define`)
  }
  if (!failed) console.log(`${name}: valid`)
}
process.exit(failed ? 1 : 0)
