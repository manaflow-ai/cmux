// The owner decision of the CI production migration (prod-owner.ts, cmux-vm.yml migrate-production):
// decided from catalog reads before anything on cmux-prod main is written.
import { describe, expect, it } from "bun:test"
import { decideOwner, directUrl, grantStatements, ownersOf, productionUrl, type PsRole } from "../prod-owner.ts"
import { REQUIRED_SCHEMA } from "../../../../workers/cmux-vm/src/db/schema-requirements.ts"

const owner: PsRole = { id: "own1", name: "cmux-vm-owner", pgUser: "pscale_api_owner" }
const old: PsRole = { id: "old1", name: "cmux-vm-migrator", pgUser: "pscale_api_old" }
const worker: PsRole = { id: "wrk1", name: "cmux-vm-worker", pgUser: "pscale_api_worker" }
const none = () => 0

describe("decideOwner", () => {
  it("passes when cmux-vm-owner already owns every object", () => {
    expect(decideOwner({ owner, owners: [owner.pgUser], roles: [owner, worker], outside: none })).toEqual({ kind: "ok" })
  })

  it("reassigns from the one PlanetScale role that owns cmux_vm and nothing else", () => {
    expect(decideOwner({ owner: undefined, owners: [old.pgUser], roles: [old, worker], outside: none })).toEqual({ kind: "reassign", from: old })
    expect(decideOwner({ owner, owners: [old.pgUser], roles: [owner, old], outside: none })).toEqual({ kind: "reassign", from: old })
  })

  it("refuses a role that also owns objects outside cmux_vm", () => {
    const d = decideOwner({ owner: undefined, owners: [old.pgUser], roles: [old], outside: (r) => (r === old.pgUser ? 3 : 0) })
    expect(d.kind).toBe("refuse")
    if (d.kind === "refuse") expect(d.why).toContain("3 object(s) outside cmux_vm")
  })

  it("never moves postgres's, pscale_admin's or a pg_* role's objects", () => {
    for (const r of ["postgres", "pscale_admin", "pg_database_owner"]) expect(decideOwner({ owner: undefined, owners: [r], roles: [], outside: none }).kind).toBe("refuse")
  })

  it("refuses several owners, a SQL role with no PlanetScale record, and an empty schema", () => {
    expect(decideOwner({ owner: undefined, owners: [old.pgUser, worker.pgUser], roles: [old, worker], outside: none }).kind).toBe("refuse")
    expect(decideOwner({ owner: undefined, owners: ["cmux_vm_migrator"], roles: [old], outside: none }).kind).toBe("refuse")
    expect(decideOwner({ owner: undefined, owners: [], roles: [], outside: none }).kind).toBe("refuse")
  })
})

describe("ownersOf", () => {
  it("lists each owner once, sorted", () => {
    expect(ownersOf({ trackingTable: false, objects: [{ kind: "schema", owner: "b", n: 1 }, { kind: "relation:r", owner: "a", n: 4 }, { kind: "type", owner: "b", n: 8 }] })).toEqual(["a", "b"])
  })
})

describe("productionUrl", () => {
  it("accepts only a login on cmux-prod main", () => {
    expect(productionUrl("postgresql://worker.pj68ww4tuq8x:pw@host:5432/postgres", "U")).toContain("pj68ww4tuq8x")
    expect(() => productionUrl("postgresql://worker.qjkoajlaike8:pw@host:5432/postgres", "U")).toThrow("not for cmux-prod/main")
    expect(() => productionUrl(undefined, "U")).toThrow("U is empty")
    expect(() => productionUrl("not a url", "U")).toThrow("not a URL")
  })
})

describe("directUrl", () => {
  it("moves a pooler URL to the direct port", () => {
    expect(new URL(directUrl("postgresql://w.pj68ww4tuq8x:pw@h.example:6432/postgres")).port).toBe("5432")
  })
})

describe("grantStatements", () => {
  it("grants USAGE and every required table privilege, all in cmux_vm", () => {
    const s = grantStatements(REQUIRED_SCHEMA, "pscale_api_worker")
    expect(s[0]).toBe('GRANT USAGE ON SCHEMA cmux_vm TO "pscale_api_worker"')
    expect(s).toContain('GRANT SELECT, INSERT, UPDATE ON TABLE cmux_vm.vm_client_sessions TO "pscale_api_worker"')
    for (const line of s.slice(1)) expect(line).toMatch(/^GRANT [A-Z, ]+ ON TABLE cmux_vm\.[a-z0-9_]+ TO "pscale_api_worker"$/)
  })

  it("refuses a table outside cmux_vm or a privilege beyond DML", () => {
    expect(() => grantStatements([{ table: "public.users", privileges: ["SELECT"], migration: "0001" } as never], "w")).toThrow("not a plain table in cmux_vm")
    expect(() => grantStatements([{ table: "cmux_vm.x", privileges: ["TRUNCATE"], migration: "0001" } as never], "w")).toThrow("only SELECT")
  })
})
