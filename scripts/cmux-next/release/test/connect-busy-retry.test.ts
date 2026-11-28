// Detector connect-busy-retry: a release script that reaches a real database connects through
// connectRetrying, so a full server (53300 "remaining connection slots are reserved ...", 57P03) waits
// about 2 min instead of failing the step. cmux VM / migrate production (cmux_vm) went red on 2026-11-28
// (run 46174628678) because prod-owner.ts called connectUrl bare. Tests may connect directly.
import { describe, expect, it } from "bun:test"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"

const DIR = join(import.meta.dir, "..")

describe("connect-busy-retry", () => {
  it("no release script calls connectUrl except through connectRetrying", () => {
    const bare: Array<string> = []
    for (const f of readdirSync(DIR).filter((n) => n.endsWith(".ts") && n !== "runner.ts")) {
      readFileSync(join(DIR, f), "utf8").split("\n").forEach((line, i) => {
        if (/\bconnectUrl\(/.test(line) && !/connectRetrying\(connectUrl\b/.test(line)) bare.push(`${f}:${i + 1}: ${line.trim()}`)
      })
    }
    expect(bare).toEqual([])
  })
})
