import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { scanCalls } from "./l10n-scan.ts"

const dir = join(import.meta.dir, "..")
const table = (lang: string) => JSON.parse(readFileSync(join(dir, `strings/${lang}.json`), "utf8")) as Record<string, string>
const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()

describe("strings", () => {
  const used = scanCalls(join(dir, "src"))

  test("strings/en.json is exactly the English of every t() call", () => {
    expect(table("en")).toEqual(Object.fromEntries([...used.entries()].sort(([a], [b]) => a.localeCompare(b))))
  })

  test("strings/ja.json has every key, no extra keys, the same placeholders, no empty values", () => {
    const ja = table("ja")
    expect(Object.keys(ja).sort()).toEqual([...used.keys()].sort())
    for (const [key, english] of used) {
      expect(ja[key]!.length).toBeGreaterThan(0)
      expect([key, placeholders(ja[key]!)]).toEqual([key, placeholders(english)])
    }
  })

  test("the app renders in Japanese when the host locale is Japanese", async () => {
    const host = new FakeHost("", { app: { id: "cmux/caffeinate", version: "0.1.0" }, apiVersion: "1.0.0" })
    host.eval(`Intl.DateTimeFormat = function () { return { resolvedOptions: () => ({ locale: "ja-JP" }) } }`)
    host.eval(readFileSync(join(dir, "dist/main.js"), "utf8"))
    host.global.__cmuxAppInit(JSON.stringify({ app: { id: "cmux/caffeinate", version: "0.1.0" }, apiVersion: "1.0.0", settings: { variant: "pane" } }))
    host.handlers = { "power.assertion.list": () => ({ ok: true, body: { value: { revision: "1", available: true, assertions: [] } } }) }
    host.mount("p", "renderPane")
    await host.settle(30)
    const shown = [...host.tree("p").nodes.values()].map((n) => n.props.text)
    expect(shown).toEqual(expect.arrayContaining(["ディスプレイ", "期間", "早めに終わる条件"]))
  })
})
