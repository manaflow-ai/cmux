import { afterEach, describe, expect, test } from "bun:test"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"
import { setLanguage, t } from "../src/l10n.ts"
import { ago, clock, snoozePresets } from "../src/time.ts"

const root = join(import.meta.dir, "..")
const files = (dir: string): string[] => readdirSync(dir).flatMap((n) => (statSync(join(dir, n)).isDirectory() ? files(join(dir, n)) : n.endsWith(".ts") ? [join(dir, n)] : []))
const table = (lang: string) => JSON.parse(readFileSync(join(root, "strings", `${lang}.json`), "utf8")) as Record<string, string>
const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()

afterEach(() => setLanguage(null))

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

  test("falls back to the bundled table for the language and fills placeholders", () => {
    setLanguage("ja-JP")
    expect(t("kind.choice")).toBe("選択")
    expect(t("card.position", { index: 2, total: 9 })).toBe("2 / 9")
    setLanguage("fr")
    expect(t("card.position", { index: 2, total: 9 })).toBe("2 of 9")
    expect(t("no.such.key")).toBe("no.such.key")
  })
})

describe("time", () => {
  const now = new Date(2026, 9, 2, 14, 5).getTime() // Friday 14:05 local
  test("ago is compact", () => {
    expect(ago(now - 20_000, now)).toBe("now")
    expect(ago(now - 5 * 60_000, now)).toBe("5m")
    expect(ago(now - 3 * 3_600_000, now)).toBe("3h")
    expect(ago(now - 2 * 86_400_000, now)).toBe("2d")
    expect(ago(now - 15 * 86_400_000, now)).toBe("2w")
  })

  test("snooze presets name their wake time", () => {
    const presets = snoozePresets(now)
    expect(presets.map((p) => p.label)).toEqual(["In 30 minutes (14:35)", "In 2 hours (16:05)", "Tomorrow (9:00)", "Next week (Mon 9:00)"])
    expect(new Date(presets[3]!.until).getDay()).toBe(1)
    expect(clock(new Date(2026, 9, 5, 9, 0).getTime(), new Date(2026, 9, 5, 7, 0).getTime())).toBe("9:00")
    const monday = new Date(2026, 9, 5, 10, 0).getTime()
    expect(new Date(snoozePresets(monday)[3]!.until).getDate()).toBe(12)
  })
})
