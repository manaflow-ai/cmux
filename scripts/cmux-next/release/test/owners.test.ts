// Which role owns each target's migrated objects (release-rails.md, "cmux_vm-only owner role").
// Staging moved to the SQL role cmux_vm_migrator on 2026-10-09; production's first owner is the
// PlanetScale role cmux-vm-owner on main, created by the PlanetScale API with no inherited roles,
// so no creator keeps a membership in it (the staging residual).
import { describe, expect, it } from "bun:test"
import { ownerPgRoleOf, TREES } from "../trees.ts"

describe("cmux-vm owner per target", () => {
  it("staging and development check the SQL role cmux_vm_migrator", () => {
    expect(ownerPgRoleOf(TREES["cmux-vm"], "staging")).toBe("cmux_vm_migrator")
    expect(ownerPgRoleOf(TREES["cmux-vm"], "development")).toBe("cmux_vm_migrator")
  })

  it("production checks the PlanetScale role cmux-vm-owner through pscale, not a SQL role", () => {
    expect(ownerPgRoleOf(TREES["cmux-vm"], "production")).toBeUndefined()
    expect(TREES["cmux-vm"].ownerRole).toBe("cmux-vm-owner")
  })

  it("backend has no SQL owner role on any target", () => {
    for (const target of ["development", "staging", "production"] as const) expect(ownerPgRoleOf(TREES.backend, target)).toBeUndefined()
  })
})
