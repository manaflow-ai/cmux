/**
 * The Postgres to Vitess projection switches in backend/apps/api/wrangler.jsonc (cmuxterm-hq#4767):
 * every projection read goes to Vitess, and a switch that sends projection writes or the credits mirror
 * to MySQL, or keeps a Postgres primary or shadow, is set only where its Hyperdrive bindings are, so a
 * cutover config without its bindings fails here instead of in the deployed Worker.
 */
import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { stripJsonc } from "../worker-release.ts"

type Env = { vars?: Record<string, string>; hyperdrive?: Array<{ binding: string; id: string }> }
const doc = JSON.parse(stripJsonc(readFileSync(join(import.meta.dir, "../../../../backend/apps/api/wrangler.jsonc"), "utf8"))) as { env: Record<string, Env> }

/** The bindings an environment's switches need (projection-targets.ts, home-search-mysql.ts, feed-sweep.ts, credits-mirror.ts). */
const neededBindings = (vars: Record<string, string>): Array<string> => {
  // Reads (home.search, the feed sweep) always go to the Vitess reader.
  const need = new Set<string>(["PS_MYSQL_RO"])
  if (vars.PROJECTION_PRIMARY === "mysql" || vars.PROJECTION_SHADOW === "mysql" || vars.CREDITS_MIRROR === "mysql") need.add("PS_MYSQL")
  // Postgres is written while it is the primary or the shadow.
  if (vars.PROJECTION_PRIMARY !== "mysql" || vars.PROJECTION_SHADOW === "postgres") need.add("HYPERDRIVE")
  return [...need].sort()
}

describe("projection switches in wrangler.jsonc", () => {
  for (const name of ["development", "staging", "production"]) {
    const env = doc.env[name]!
    it(`${name}: every projection switch has its Hyperdrive bindings`, () => {
      const have = new Set((env.hyperdrive ?? []).map((h) => h.binding))
      expect(neededBindings(env.vars ?? {}).filter((b) => !have.has(b))).toEqual([])
    })
    it(`${name}: sets no retired read switch or Postgres reader binding`, () => {
      expect(Object.keys(env.vars ?? {})).not.toContain("PROJECTION_READS")
      expect((env.hyperdrive ?? []).map((h) => h.binding)).not.toContain("HYPERDRIVE_RO")
    })
  }

  it("a switch without its bindings is refused", () => {
    expect(neededBindings({})).toEqual(["HYPERDRIVE", "PS_MYSQL_RO"])
    expect(neededBindings({ PROJECTION_SHADOW: "mysql" })).toEqual(["HYPERDRIVE", "PS_MYSQL", "PS_MYSQL_RO"])
    expect(neededBindings({ PROJECTION_PRIMARY: "mysql", PROJECTION_SHADOW: "postgres", CREDITS_MIRROR: "mysql" })).toEqual(["HYPERDRIVE", "PS_MYSQL", "PS_MYSQL_RO"])
    expect(neededBindings({ PROJECTION_PRIMARY: "mysql" })).toEqual(["PS_MYSQL", "PS_MYSQL_RO"])
  })
})
