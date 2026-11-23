#!/usr/bin/env bun
// Builds (or with --check verifies) every first-party app's dist/main.js and
// validates its manifest. Plan: plans/cmux-next/first-party-apps.md.
// An app whose cmux-app.json is manifest v2 (an SDK extension, such as the store widgets) is
// checked against the v2 schema and its interface exports, as examples/extensions/build.ts does;
// the Rust validator checks the same packages (cmux-app-manifest tests/samples.rs).
// Usage: bun first-party-apps/build.ts [--check] [<name>...]
import { readdirSync, readFileSync, statSync, existsSync } from "node:fs"
import { join } from "node:path"
import { SchemaValidator } from "../cmux-tui/crates/cmux-app-host/tools/json-schema.ts"
const here = new URL(".", import.meta.url).pathname
const tools = join(here, "../cmux-tui/crates/cmux-app-host/tools")
const args = process.argv.slice(2)
const check = args.includes("--check")
const only = args.filter((a) => !a.startsWith("--"))
let failed = false
const read = (p: string) => JSON.parse(readFileSync(p, "utf8"))
let v2Schema: SchemaValidator | undefined
/** A v2 cmux-app.json: the v2 schema, and every interface's export defined by dist/main.js. */
function validateV2(name: string, dir: string, manifest: Record<string, unknown>): boolean {
  v2Schema ??= new SchemaValidator(read(join(tools, "../schema/v2/cmux-app.schema.json")))
  let ok = true
  for (const e of v2Schema.validate(manifest)) {
    console.error(`${name}: cmux-app.json ${e.path || "/"} ${e.message}`)
    ok = false
  }
  const main = readFileSync(join(dir, "dist/main.js"), "utf8")
  for (const [iface, impl] of Object.entries((manifest.implements ?? {}) as Record<string, { export?: string }>)) {
    if (impl.export && !main.includes(`function ${impl.export}(`)) {
      console.error(`${name}: ${iface} names ${impl.export}, which dist/main.js does not define`)
      ok = false
    }
  }
  for (const path of [manifest.icon, ...((manifest.screenshots ?? []) as unknown[])]) {
    if (typeof path === "string" && !existsSync(join(dir, path))) {
      console.error(`${name}: ${path} is missing`)
      ok = false
    }
  }
  if (ok) console.log(`${name}: valid (manifest v2)`)
  return ok
}
const names = readdirSync(here)
  .filter((n) => statSync(join(here, n)).isDirectory() && existsSync(join(here, n, "cmux-app.json")))
  .filter((n) => only.length === 0 || only.includes(n))
  .sort()
for (const name of names) {
  const dir = join(here, name)
  const pack = Bun.spawnSync(["bun", join(tools, "pack.ts"), dir, ...(check ? ["--check"] : [])], { stdout: "inherit", stderr: "inherit" })
  const manifest = read(join(dir, "cmux-app.json"))
  const valid =
    manifest.manifestVersion === 2
      ? validateV2(name, dir, manifest)
      : Bun.spawnSync(["bun", join(tools, "validate-manifest.ts"), dir], { stdout: "inherit", stderr: "inherit" }).exitCode === 0
  if (pack.exitCode !== 0 || !valid) failed = true
}
if (names.length === 0) console.log("no first-party apps found")
process.exit(failed ? 1 : 0)
