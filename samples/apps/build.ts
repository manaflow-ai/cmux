#!/usr/bin/env bun
// Builds (or with --check verifies) every sample app's dist/main.js and validates it.
import { existsSync, readdirSync, statSync } from "node:fs"
import { join } from "node:path"
const here = new URL(".", import.meta.url).pathname
const tools = join(here, "../../cmux-tui/crates/cmux-app-host/tools")
const check = process.argv.includes("--check")
let failed = false
for (const name of readdirSync(here).filter((n) => statSync(join(here, n)).isDirectory()).sort()) {
  const dir = join(here, name)
  // A manifest-v2-only sample (no JS runtime, for example ssh-terminal) is validated by its own Rust test with cmux-app-manifest.
  if (!existsSync(join(dir, "cmux-app.json")) && existsSync(join(dir, "cmux-app.v2.json"))) continue
  const pack = Bun.spawnSync(["bun", join(tools, "pack.ts"), dir, ...(check ? ["--check"] : [])], { stdout: "inherit", stderr: "inherit" })
  const validate = Bun.spawnSync(["bun", join(tools, "validate-manifest.ts"), dir], { stdout: "inherit", stderr: "inherit" })
  if (pack.exitCode !== 0 || validate.exitCode !== 0) failed = true
}
process.exit(failed ? 1 : 0)
