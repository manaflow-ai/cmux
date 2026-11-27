// The app's strings: every t() key in src has English and Japanese, placeholders kept.
import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { scanCalls } from "./l10n-scan.ts"

describe("localization", () => {
  const en = JSON.parse(readFileSync(join(import.meta.dir, "../strings/en.json"), "utf8")) as Record<string, string>
  const ja = JSON.parse(readFileSync(join(import.meta.dir, "../strings/ja.json"), "utf8")) as Record<string, string>
  const used = scanCalls(join(import.meta.dir, "../src"))

  test("every key in src has English and Japanese, and English matches the call site", () => {
    for (const [key, english] of used) {
      expect(en[key]).toBe(english)
      expect(ja[key]).toBeString()
    }
    expect(Object.keys(en).sort()).toEqual(Object.keys(ja).sort())
  })

  test("placeholders survive translation", () => {
    for (const [key, value] of Object.entries(en)) {
      const want = [...value.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()
      const got = [...(ja[key] ?? "").matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()
      expect(`${key}:${got.join(",")}`).toBe(`${key}:${want.join(",")}`)
    }
  })
})
