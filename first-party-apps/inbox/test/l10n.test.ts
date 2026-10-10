// The app's strings: en and ja match, and every key the code uses exists.
import { describe, expect, test } from "bun:test"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"

const root = join(import.meta.dir, "..")
const files = (dir: string): string[] => readdirSync(dir).flatMap((n) => (statSync(join(dir, n)).isDirectory() ? files(join(dir, n)) : n.endsWith(".ts") ? [join(dir, n)] : []))
const table = (lang: string) => JSON.parse(readFileSync(join(root, "strings", `${lang}.json`), "utf8")) as Record<string, string>
const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()

describe("localization", () => {
  test("en and ja have the same keys and placeholders", () => {
    const en = table("en")
    const ja = table("ja")
    expect(Object.keys(ja).sort()).toEqual(Object.keys(en).sort())
    for (const key of Object.keys(en)) expect([key, placeholders(ja[key]!)]).toEqual([key, placeholders(en[key]!)])
  })

  test("every key the code uses exists, including keys built at runtime", () => {
    const en = table("en")
    const used = new Set<string>()
    for (const file of files(join(root, "src"))) for (const m of readFileSync(file, "utf8").matchAll(/\bt\(\s*"([\w.-]+)"/g)) used.add(m[1]!)
    for (const k of ["question", "choice", "approve", "confirm", "sign-in", "passkey", "review", "input", "file", "handoff"]) used.add(`kind.${k}`)
    for (const k of ["all", "agent", "harness", "integration", "automation", "app", "system", "server", "vm", "user"]) used.add(`source.${k}`)
    for (let d = 0; d < 7; d++) used.add(`day.${d}`)
    for (const id of ["30m", "2h", "tomorrow", "nextWeek"]) used.add(`snooze.${id}`)
    expect([...used].filter((k) => !(k in en))).toEqual([])
    expect(Object.keys(en).filter((k) => !used.has(k))).toEqual([])
  })
})
