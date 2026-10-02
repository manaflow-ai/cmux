#!/usr/bin/env bun
// Builds (or with --check verifies) every first-party app's dist/main.js.
// Manifest validation moved to the Rust validator (crate cmux-app-manifest,
// manifest v2 only); these apps validate there once they move to v2.
// Plan: plans/cmux-next/first-party-apps.md.
// Usage: bun first-party-apps/build.ts [--check] [<name>...]
import { readdirSync, statSync, existsSync } from "node:fs"
import { join } from "node:path"
const here = new URL(".", import.meta.url).pathname
const tools = join(here, "../cmux-tui/crates/cmux-app-host/tools")
const args = process.argv.slice(2)
const check = args.includes("--check")
const only = args.filter((a) => !a.startsWith("--"))
let failed = false
const names = readdirSync(here)
  .filter((n) => statSync(join(here, n)).isDirectory() && existsSync(join(here, n, "cmux-app.json")))
  .filter((n) => only.length === 0 || only.includes(n))
  .sort()
for (const name of names) {
  const dir = join(here, name)
  const pack = Bun.spawnSync(["bun", join(tools, "pack.ts"), dir, ...(check ? ["--check"] : [])], { stdout: "inherit", stderr: "inherit" })
  if (pack.exitCode !== 0) failed = true
}
if (names.length === 0) console.log("no first-party apps found")
process.exit(failed ? 1 : 0)
