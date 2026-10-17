import { describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { isPromotableLineage, type GitRunner } from "../prod-promote.ts"

const repo = () => {
  const root = mkdtempSync(join(tmpdir(), "prod-promote-lineage-"))
  const run: GitRunner = (args, input) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8", ...(input === undefined ? {} : { input }) }).trim()
  run(["init", "--quiet"])
  run(["config", "user.email", "test@example.com"])
  run(["config", "user.name", "Release test"])
  mkdirSync(join(root, "backend"), { recursive: true })
  const commit = (contents: string, message: string) => {
    writeFileSync(join(root, "backend", "runtime.ts"), contents)
    run(["add", "backend/runtime.ts"])
    run(["commit", "--quiet", "-m", message])
    return run(["rev-parse", "HEAD"])
  }
  return { root, run, commit }
}

describe("production promotion lineage", () => {
  it("accepts a staging history that contains a cherry-pick-equivalent production change", () => {
    const t = repo()
    const base = t.commit("export const value = 1\n", "base")
    t.run(["checkout", "--quiet", "-b", "candidate", base])
    t.commit("export const value = 2\n", "candidate implementation")
    const candidate = t.commit("export const value = 3\n", "candidate follow-up")
    t.run(["checkout", "--quiet", "-b", "production", base])
    const production = t.commit("export const value = 2\n", "production cherry-pick")

    expect(isPromotableLineage(production, candidate, t.run)).toBe(true)
    expect(isPromotableLineage(base, candidate, t.run)).toBe(true)
  })

  it("rejects a production history with an unmatched backend change", () => {
    const t = repo()
    const base = t.commit("export const value = 1\n", "base")
    t.run(["checkout", "--quiet", "-b", "candidate", base])
    const candidate = t.commit("export const value = 2\n", "candidate implementation")
    t.run(["checkout", "--quiet", "-b", "production", base])
    t.commit("export const value = 2\n", "production cherry-pick")
    const production = t.commit("export const value = 99\n", "unmatched production change")

    expect(isPromotableLineage(production, candidate, t.run)).toBe(false)
  })
})
