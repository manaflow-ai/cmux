import { describe, expect, test } from "bun:test"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { currentLocale, jaKeys, setLocale, t } from "../src/l10n.ts"
import { DEFAULTS, nextVariant, readSettings, VARIANTS } from "../src/settings.ts"

const root = join(import.meta.dir, "..")
const manifest = JSON.parse(readFileSync(join(root, "cmux-app.json"), "utf8"))

describe("settings", () => {
  test("code defaults match the manifest defaults", () => {
    const props = manifest.contributes.settings.properties
    expect(props.variant.default).toBe(DEFAULTS.variant)
    expect(props.variant.enum).toEqual([...VARIANTS])
    expect(props.variant["x-cmux-devOnly"]).toBe(true)
    expect(props.defaultScope.default).toBe(DEFAULTS.defaultScope)
    expect(props.rememberRecent.default).toBe(DEFAULTS.rememberRecent)
    expect(props.sources.default).toEqual(DEFAULTS.sources)
  })

  test("invalid values fall back to defaults", () => {
    expect(readSettings({ variant: "nope", defaultScope: 3, sources: ["files", "bogus"] })).toEqual({ ...DEFAULTS, sources: ["files"] })
  })

  test("variants cycle through every design", () => {
    expect(nextVariant("grouped")).toBe("preview")
    expect(nextVariant("palette")).toBe("grouped")
  })
})

describe("localization", () => {
  const sources = (dir: string): string[] => readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? sources(join(dir, e.name)) : e.name.endsWith(".ts") ? [join(dir, e.name)] : []))
  const used = new Set(sources(join(root, "src")).flatMap((f) => [...readFileSync(f, "utf8").matchAll(/\bt\("([\w.]+)"/g)].map((m) => m[1]!)))

  test("every key the app uses has a Japanese entry, and none is unused", () => {
    expect([...used].filter((k) => !jaKeys().includes(k))).toEqual([])
    expect(jaKeys().filter((k) => !used.has(k))).toEqual([])
  })

  test("t() fills placeholders and follows the locale", () => {
    setLocale("ja-JP")
    expect(currentLocale()).toBe("ja")
    expect(t("more", "{count} more", { count: 3 })).toBe("さらに 3 件")
    setLocale("fr")
    expect(t("more", "{count} more", { count: 3 })).toBe("3 more")
    setLocale("en")
  })

  test("manifest titles carry English and Japanese", () => {
    const titled = [manifest, ...manifest.contributes.sidebarSections, ...manifest.contributes.paneKinds, ...manifest.contributes.commands]
    for (const c of titled) expect(Object.keys(c.title ?? c.name).sort()).toEqual(["en", "ja"])
  })
})
