/** rails-hardening-2 (fifth review follow-up): one fixture per item. */
import { describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { lintFile, type TreeRoleContract } from "../lint.ts"
import { TREES } from "../trees.ts"
import { gitInit, tempRoot } from "./helpers.ts"

const contract: TreeRoleContract = { grantees: [], tablePrivileges: ["SELECT"], schemas: ["cmux_vm"], schemaPrivileges: ["USAGE"] }

describe("(1) the working tree cannot change between the check and the write", () => {
  it("stillAt refuses a migration file that changed after productionCheckout", async () => {
    const { stillAt } = await import("../guards.ts")
    const root = tempRoot()
    const head = gitInit(root)
    expect(() => stillAt(root, TREES["cmux-vm"], head)).not.toThrow()
    writeFileSync(join(root, "workers/cmux-vm/migrations/0001_cmux_vm_ownership.sql"), "-- changed\n")
    expect(() => stillAt(root, TREES["cmux-vm"], head)).toThrow("uncommitted")
  })
})

describe("(2) runtime injection and the pinned runtime", () => {
  it("refuses library-path variables, a home or XDG bunfig preload and a --preload flag", async () => {
    const { runtimeInjection } = await import("../guards.ts")
    for (const v of ["DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "LD_LIBRARY_PATH", "LD_AUDIT"]) expect(runtimeInjection({ [v]: "/tmp/x" }, [], [], {}).join()).toContain(v)
    const home = mkdtempSync(join(tmpdir(), "rails-home-"))
    writeFileSync(join(home, ".bunfig.toml"), 'preload = ["./evil.ts"]\n')
    expect(runtimeInjection({}, [], [], { home }).join()).toContain(".bunfig.toml has a preload")
    const xdg = mkdtempSync(join(tmpdir(), "rails-xdg-"))
    writeFileSync(join(xdg, ".bunfig.toml"), 'preload = ["./evil.ts"]\n')
    expect(runtimeInjection({ XDG_CONFIG_HOME: xdg }, [], [], {}).join()).toContain(".bunfig.toml has a preload")
    expect(runtimeInjection({}, [], ["--preload", "./evil.ts"], {}).join()).toContain("--preload")
    expect(runtimeInjection({ BUN_INSTALL: "/opt/bun", PATH: "/usr/bin" }, [], [], {})).toEqual([])
  })
  it("lint refuses a pg (or libpg-query) install that differs from the pinned runtime digest", async () => {
    const { runtimeProblems } = await import("../lint.ts")
    expect(runtimeProblems()).toEqual([])
    expect(runtimeProblems({ packages: ["pg"], sha256: "0".repeat(64) }).join()).toContain("runtime packages")
  })
})

describe("(5) COMMENT ON TYPE reads the type name", () => {
  it("accepts a cmux_vm type and refuses another schema's", async () => {
    const ok = await lintFile(TREES["cmux-vm"], "0010_x.sql", "COMMENT ON TYPE cmux_vm.mode IS 'x';\n", contract)
    expect(ok.errors).toEqual([])
    const bad = await lintFile(TREES["cmux-vm"], "0010_x.sql", "COMMENT ON TYPE public.mode IS 'x';\n", contract)
    expect(bad.errors.length).toBeGreaterThan(0)
  })
})
