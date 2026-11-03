/**
 * The Postgres to Vitess projection switches in backend/apps/api/wrangler.jsonc (cmuxterm-hq#4767):
 * every environment runs the 15-minute compare cron, and a switch that sends projection writes, reads,
 * the credits mirror or the compare to MySQL is set only where its Hyperdrive bindings are, so a
 * cutover config without the PlanetScale bindings fails here instead of in the deployed Worker.
 */
import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { stripJsonc } from "../worker-release.ts"

type Env = { vars?: Record<string, string>; triggers?: { crons?: Array<string> }; hyperdrive?: Array<{ binding: string; id: string }> }
const doc = JSON.parse(stripJsonc(readFileSync(join(import.meta.dir, "../../../../backend/apps/api/wrangler.jsonc"), "utf8"))) as { env: Record<string, Env> }

/** The bindings an environment's switches need (projection-targets.ts, projection-reads.ts, credits-mirror.ts, projection-compare-cron.ts). */
const neededBindings = (vars: Record<string, string>): Array<string> => {
  const need = new Set<string>()
  const primaryMysql = vars.PROJECTION_PRIMARY === "mysql"
  if (primaryMysql || vars.PROJECTION_SHADOW === "mysql" || vars.CREDITS_MIRROR === "mysql") need.add("PS_MYSQL")
  if (vars.PROJECTION_READS === "mysql" || vars.PROJECTION_READS === "shadow") need.add("PS_MYSQL_RO")
  // The compare runs while either side is MySQL and reads both databases.
  if (primaryMysql || vars.PROJECTION_SHADOW === "mysql") for (const b of ["HYPERDRIVE", "PS_MYSQL_RO"]) need.add(b)
  if (!primaryMysql || vars.PROJECTION_SHADOW === "postgres" || vars.PROJECTION_READS !== "mysql") need.add("HYPERDRIVE")
  // Postgres reads (home.search; the feed sweep falls back to it) while reads are not MySQL only.
  if (vars.PROJECTION_READS !== "mysql") need.add("HYPERDRIVE_RO")
  return [...need].sort()
}

describe("projection switches in wrangler.jsonc", () => {
  for (const name of ["development", "staging", "production"]) {
    const env = doc.env[name]!
    it(`${name}: runs the */15 projection compare cron`, () => {
      expect(env.triggers?.crons ?? []).toContain("*/15 * * * *")
    })
    it(`${name}: every projection switch has its Hyperdrive bindings`, () => {
      const have = new Set((env.hyperdrive ?? []).map((h) => h.binding))
      expect(neededBindings(env.vars ?? {}).filter((b) => !have.has(b))).toEqual([])
    })
  }

  // The hourly full read-only verify (projection-compare-full-cron.ts): staging only. Production adds the
  // trigger in its own config PR when the cutover runbook asks (cmuxterm-hq#4767 step 5).
  it("the hourly full projection verify runs on staging and not yet in production", () => {
    expect(doc.env.staging!.triggers?.crons ?? []).toContain("7 * * * *")
    expect(doc.env.production!.triggers?.crons ?? []).not.toContain("7 * * * *")
  })

  it("a MySQL switch without the PlanetScale bindings is refused", () => {
    expect(neededBindings({})).toEqual(["HYPERDRIVE", "HYPERDRIVE_RO"])
    expect(neededBindings({ PROJECTION_SHADOW: "mysql", PROJECTION_READS: "shadow" })).toEqual(["HYPERDRIVE", "HYPERDRIVE_RO", "PS_MYSQL", "PS_MYSQL_RO"])
    expect(neededBindings({ PROJECTION_PRIMARY: "mysql", PROJECTION_READS: "mysql", PROJECTION_SHADOW: "postgres", CREDITS_MIRROR: "mysql" })).toEqual(["HYPERDRIVE", "PS_MYSQL", "PS_MYSQL_RO"])
    // The compare still reads Postgres while MySQL is the primary, until the Postgres path is removed (step 8).
    expect(neededBindings({ PROJECTION_PRIMARY: "mysql", PROJECTION_READS: "mysql" })).toEqual(["HYPERDRIVE", "PS_MYSQL", "PS_MYSQL_RO"])
  })
})
