// The tests render with marked, an npm package. When the pinned packages are missing (a fresh
// checkout, CI, a fork), install them from bun.lock and run `bun test` again in a new process:
// this one already looked for node_modules and would not see the install.
import { existsSync } from "node:fs"
import { join } from "node:path"

const dir = join(import.meta.dir, "..")
if (!existsSync(join(dir, "node_modules/marked/package.json"))) {
  const install = Bun.spawnSync(["bun", "install", "--frozen-lockfile"], { cwd: dir, stdout: "inherit", stderr: "inherit" })
  if (install.exitCode !== 0) throw new Error(`bun install --frozen-lockfile failed in ${dir} (exit ${install.exitCode})`)
  const again = Bun.spawnSync(["bun", "test"], { cwd: process.cwd(), stdout: "inherit", stderr: "inherit", env: process.env })
  process.exit(again.exitCode ?? 1)
}
