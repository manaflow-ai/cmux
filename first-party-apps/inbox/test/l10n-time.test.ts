import { afterEach, describe, expect, test } from "bun:test"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"
import { setLanguage, t, translationKeys } from "../src/l10n.ts"
import { ago, clock, snoozePresets } from "../src/time.ts"

const src = join(import.meta.dir, "../src")
const files = (dir: string): string[] => readdirSync(dir).flatMap((n) => (statSync(join(dir, n)).isDirectory() ? files(join(dir, n)) : n.endsWith(".ts") ? [join(dir, n)] : []))

/** Every literal key with its English text: t("key", "English") and ["key", "English"] tables. */
function englishStrings(): Map<string, string> {
  const out = new Map<string, string>()
  for (const file of files(src)) {
    const text = readFileSync(file, "utf8")
    for (const m of text.matchAll(/\bt\(\s*"([a-z]\w*\.[\w.]+)",\s*"((?:[^"\\]|\\.)*)"/g)) out.set(m[1]!, m[2]!)
    // Label tables: ["kind.agentBlocked", "Needs input"] (English starts with a capital).
    for (const m of text.matchAll(/\[\s*"([a-z]\w*\.[\w.]+)",\s*"([A-Z](?:[^"\\]|\\.)*)"/g)) out.set(m[1]!, m[2]!)
  }
  return out
}

const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()

afterEach(() => setLanguage("en"))

describe("localization", () => {
  test("every English string has a Japanese translation with the same placeholders", () => {
    const english = englishStrings()
    const ja = new Set(translationKeys("ja"))
    // Keys built at runtime.
    for (let d = 0; d < 7; d++) english.set(`day.${d}`, "")
    for (const id of ["30m", "2h", "tomorrow", "nextWeek"]) english.set(`snooze.${id}`, "{time}")
    expect(english.size).toBeGreaterThan(60)
    const missing = [...english.keys()].filter((k) => !ja.has(k))
    expect(missing).toEqual([])
    setLanguage("ja")
    for (const [key, en] of english) if (en) expect([key, placeholders(t(key, en))]).toEqual([key, placeholders(en)])
  })

  test("falls back to English and fills placeholders", () => {
    expect(t("nope.key", "Hello {name}", { name: "Ada" })).toBe("Hello Ada")
    setLanguage("ja-JP")
    expect(t("kind.agentBlocked", "Needs input")).toBe("入力待ち")
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
    // On a Monday, "next week" is a week later.
    const monday = new Date(2026, 9, 5, 10, 0).getTime()
    expect(new Date(snoozePresets(monday)[3]!.until).getDate()).toBe(12)
  })
})
