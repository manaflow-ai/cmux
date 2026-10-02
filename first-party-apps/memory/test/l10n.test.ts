import { describe, expect, test } from "bun:test"
import en from "../strings/en.json"
import ja from "../strings/ja.json"
import { dynamicCalls, scanCalls } from "./l10n-scan.ts"

const src = new URL("../src", import.meta.url).pathname
const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()

describe("strings", () => {
  const calls = scanCalls(src)

  test("every key in the source is in both tables, with the same English", () => {
    for (const [key, english] of calls) {
      expect((en as Record<string, string>)[key]).toBe(english)
      expect((ja as Record<string, string>)[key]).toBeString()
    }
  })

  test("no unused keys and no dynamic keys", () => {
    expect(Object.keys(en).filter((k) => !calls.has(k))).toEqual([])
    expect(Object.keys(ja).sort()).toEqual(Object.keys(en).sort())
    expect(dynamicCalls(src)).toEqual([])
  })

  test("placeholders match between languages", () => {
    for (const key of Object.keys(en)) expect(placeholders((ja as Record<string, string>)[key]!)).toEqual(placeholders((en as Record<string, string>)[key]!))
  })
})
