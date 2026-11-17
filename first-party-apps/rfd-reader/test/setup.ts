// The tests render with marked, an npm package. When the pinned packages are missing (a fresh
// checkout, CI, a fork), install them from bun.lock and run `bun test` again in a new process:
// this one already looked for node_modules and would not see the install.
import { existsSync } from "node:fs"
import { join } from "node:path"

const dir = join(import.meta.dir, "..")
if (!existsSync(join(dir, "node_modules/marked/package.json"))) {
  const install = Bun.spawnSync(["bun", "install", "--frozen-lockfile"], { cwd: dir, stdout: "inherit", stderr: "inherit" })
  if (install.exitCode !== 0) throw new Error(`bun install --frozen-lockfile failed in ${dir} (exit ${install.exitCode})`)
  // Bun gives a preload the test files it runs (not the flags): run those again, from this app, so a
  // targeted run stays targeted and never widens to the whole repository.
  const files = process.argv.slice(1).filter((f) => /\.(test|spec)\.[jt]sx?$/.test(f))
  const again = Bun.spawnSync([process.execPath, "test", ...(files.length ? files : [join(dir, "test")])], { cwd: dir, stdout: "inherit", stderr: "inherit", env: process.env })
  process.exit(again.exitCode ?? 1)
}
