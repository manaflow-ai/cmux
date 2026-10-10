// The app's strings: every t() key in src has English and Japanese.
import { describe, expect, test } from "bun:test"
import { scanCalls } from "./l10n-scan.ts"

describe("localization", () => {
  test("every t() key has English and Japanese strings", async () => {
    const en = await Bun.file(new URL("../strings/en.json", import.meta.url)).json()
    const ja = await Bun.file(new URL("../strings/ja.json", import.meta.url)).json()
    const calls = scanCalls(new URL("../src", import.meta.url).pathname)
    for (const [key, english] of calls) {
      expect([key, en[key]]).toEqual([key, english])
      expect([key, typeof ja[key]]).toEqual([key, "string"])
    }
    expect(Object.keys(ja).sort()).toEqual(Object.keys(en).sort())
  })
})
