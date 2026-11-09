/** db-connections.ts without a database: the PgBouncer fallback, the usage line and the table. */
import { describe, expect, it } from "bun:test"
import { bouncerUrl, connect, isFull, table, usageLine } from "../db-connections.ts"

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
