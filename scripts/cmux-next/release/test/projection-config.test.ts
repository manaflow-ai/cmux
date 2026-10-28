/**
 * The projection in backend/apps/api/wrangler.jsonc after the Postgres to Vitess migration (cmuxterm-hq#4767):
 * every environment writes and reads Vitess through PS_MYSQL / PS_MYSQL_RO, and no Postgres switch or binding
 * comes back, so a config without its bindings fails here instead of in the deployed Worker.
 */
import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { stripJsonc } from "../worker-release.ts"

type Env = { vars?: Record<string, string>; hyperdrive?: Array<{ binding: string; id: string }> }
const doc = JSON.parse(stripJsonc(readFileSync(join(import.meta.dir, "../../../../backend/apps/api/wrangler.jsonc"), "utf8"))) as { env: Record<string, Env> }

/** The bindings the projection needs (projection-targets.ts, home-search-mysql.ts, feed-sweep.ts, credits-mirror.ts). */
const neededBindings = (vars: Record<string, string>): Array<string> =>
  // A self-hosted chat server (PROJECTION_PRIMARY=none) has no projection; every hosted Worker writes and reads Vitess.
  vars.PROJECTION_PRIMARY === "none" ? [] : ["PS_MYSQL", "PS_MYSQL_RO"]

describe("projection switches in wrangler.jsonc", () => {
  for (const name of ["development", "staging", "production"]) {
    const env = doc.env[name]!
    it(`${name}: every projection switch has its Hyperdrive bindings`, () => {
      const have = new Set((env.hyperdrive ?? []).map((h) => h.binding))
      expect(neededBindings(env.vars ?? {}).filter((b) => !have.has(b))).toEqual([])
    })
    it(`${name}: sets no retired switch and no Postgres binding`, () => {
      for (const v of ["PROJECTION_READS", "PROJECTION_SHADOW"]) expect(Object.keys(env.vars ?? {})).not.toContain(v)
      expect(env.vars?.PROJECTION_PRIMARY ?? "mysql").toBe("mysql")
      for (const b of ["HYPERDRIVE", "HYPERDRIVE_RO"]) expect((env.hyperdrive ?? []).map((h) => h.binding)).not.toContain(b)
    })
  }

  it("every hosted Worker needs both Vitess bindings", () => {
    expect(neededBindings({})).toEqual(["PS_MYSQL", "PS_MYSQL_RO"])
    expect(neededBindings({ CREDITS_MIRROR: "mysql" })).toEqual(["PS_MYSQL", "PS_MYSQL_RO"])
    expect(neededBindings({ PROJECTION_PRIMARY: "none" })).toEqual([])
  })
})
