/** db-connections.ts and staging-connections.ts without a database or pscale: the PgBouncer fallback, the usage line, grouping and what may be ended. */
import { describe, expect, it } from "bun:test"
import { bouncerUrl, connect, isFull, table, usageLine } from "../db-connections.ts"
import { bareUser, groupsOf, killable, rowsOf } from "../staging-connections.ts"

const full = Object.assign(new Error("remaining connection slots are reserved for roles with the SUPERUSER attribute"), { code: "53300" })
const fakeClient = { query: async () => [], end: async () => {} }

describe("db-connections", () => {
  it("moves only the port to PgBouncer's 6432", () => {
    expect(bouncerUrl("postgresql://u.b:p@h.example:5432/db?sslmode=require")).toBe("postgresql://u.b:p@h.example:6432/db?sslmode=require")
  })

  it("tries PgBouncer only when the server is full", async () => {
    const tried: Array<string> = []
    const open = async (url: string) => {
      tried.push(new URL(url).port)
      if (new URL(url).port === "5432") throw full
      return fakeClient
    }
    const { route } = await connect("postgresql://u:p@h:5432/db", open)
    expect(route).toBe("pgbouncer")
    expect(tried).toEqual(["5432", "6432"])
    const other = Object.assign(new Error("password authentication failed"), { code: "28P01" })
    await expect(connect("postgresql://u:p@h:5432/db", async () => { throw other })).rejects.toBe(other)
    expect(isFull(full)).toBe(true)
  })

  it("warns at 80 % of the open slots", () => {
    expect(usageLine(40, 53, 3)).toEqual({ line: "40 of 50 open slots used (80 %; max_connections 53, 3 reserved)", warn: true })
    expect(usageLine(10, 53, 3).warn).toBe(false)
  })

  it("prints one row per group", () => {
    const rows = table([{ usename: "w", app: "-", state: "idle", n: 3, max_idle_s: 5, max_age_s: null }])
    expect(rows.at(-1)).toBe("| w | - | idle | 3 | 5 | ? |")
  })
})

describe("staging-connections", () => {
  const rows = [
    { connection_id: "c1", pid: 1, state: "idle", duration_ms: 600_000, username: "wrk.qjkoajlaike8", application_name: "", transaction_id: null },
    { connection_id: "c2", pid: 2, state: "idle", duration_ms: 10_000, username: "wrk.qjkoajlaike8", application_name: "", transaction_id: null },
    { connection_id: "c3", pid: 3, state: "idle in transaction", duration_ms: 600_000, username: "wrk.qjkoajlaike8", application_name: "", transaction_id: "t3" },
    { connection_id: "c4", pid: 4, state: "active", duration_ms: 600_000, username: "wrk", application_name: "", transaction_id: "t4" },
    { connection_id: "c5", pid: 5, state: "idle", duration_ms: 600_000, username: "web.qjkoajlaike8", application_name: "next", transaction_id: null },
  ]

  it("finds the rows in the envelope", () => {
    expect(rowsOf({ database_kind: "postgresql", instances: [{ id: "i", role: "primary" }], connections: rows })).toHaveLength(5)
    expect(rowsOf(rows)).toHaveLength(5)
    expect(rowsOf({ instances: [] })).toEqual([])
  })

  it("groups by role, application and state", () => {
    expect(groupsOf(rows)[0]).toEqual({ username: "wrk", app: "-", state: "idle", n: 2, maxSeconds: 600 })
    expect(bareUser("web.qjkoajlaike8")).toBe("web")
  })

  it("ends only our long-idle connections outside a transaction", () => {
    expect(killable(rows, new Set(["wrk"]), 120).map((r) => r.connection_id)).toEqual(["c1"])
  })
})
