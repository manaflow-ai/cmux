/** db-connections.ts without a database: the PgBouncer fallback, waiting out a full server, the usage line and the table. */
import { describe, expect, it } from "bun:test"
import { bouncerUrl, connect, connectWaiting, isFull, safeMessage, table, usageLine } from "../db-connections.ts"

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

  it("waits out a full server, then gives up at the deadline", async () => {
    let calls = 0
    let clock = 0
    const slept: Array<number> = []
    const sleep = async (ms: number) => {
      slept.push(ms)
      clock += ms
    }
    const now = () => clock
    const fullTwice = async () => {
      calls += 1
      if (calls <= 4) throw full // direct and PgBouncer, twice
      return fakeClient
    }
    expect((await connectWaiting("postgresql://u:p@h:5432/db", 60_000, fullTwice, sleep, 15_000, now)).route).toBe("direct")
    expect(slept).toEqual([15_000, 15_000])
    await expect(connectWaiting("postgresql://u:p@h:5432/db", 20_000, async () => { throw full }, sleep, 15_000, now)).rejects.toBe(full)
    await expect(connectWaiting("postgresql://u:p@h:5432/db", 0, async () => { throw full }, sleep, 15_000, now)).rejects.toBe(full)
    // Slow refusals use up the budget too: each attempt here takes 9 s of the 30 s.
    const before = slept.length
    const slowFull = async () => {
      clock += 9_000
      throw full
    }
    await expect(connectWaiting("postgresql://u:p@h:5432/db", 30_000, slowFull, sleep, 15_000, now)).rejects.toBe(full)
    expect(slept.length - before).toBe(0)
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

describe("safeMessage", () => {
  it("cuts the credentials out of a quoted URL", () => {
    expect(safeMessage(new Error("Invalid URL: postgresql://u.b:p/a@ss@h:5432/db"))).toBe("Invalid URL: <redacted>@h:5432/db")
  })
})
