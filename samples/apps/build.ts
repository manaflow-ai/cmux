#!/usr/bin/env bun
// Builds (or with --check verifies) every sample app's dist/main.js and validates it.
import { readdirSync, statSync } from "node:fs"
import { join } from "node:path"
const here = new URL(".", import.meta.url).pathname
const tools = join(here, "../../cmux-tui/crates/cmux-app-host/tools")
const check = process.argv.includes("--check")
let failed = false
for (const name of readdirSync(here).filter((n) => statSync(join(here, n)).isDirectory()).sort()) {
  const dir = join(here, name)
  const pack = Bun.spawnSync(["bun", join(tools, "pack.ts"), dir, ...(check ? ["--check"] : [])], { stdout: "inherit", stderr: "inherit" })
  const validate = Bun.spawnSync(["bun", join(tools, "validate-manifest.ts"), dir], { stdout: "inherit", stderr: "inherit" })
  if (pack.exitCode !== 0 || validate.exitCode !== 0) failed = true
}
process.exit(failed ? 1 : 0)
