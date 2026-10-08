// The editor apps share code by vendoring identical copies (until the platform
// generates interfaces and offers shared modules). This test keeps them identical.
import { describe, expect, test } from "bun:test"
import { existsSync, readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { scanCalls } from "./l10n-scan.ts"

const apps = join(import.meta.dir, "../..")
const files = (dir: string) => (existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".ts") || f.endsWith(".css") || f.endsWith(".json")).sort() : [])
const same = (rel: string, a: string, b: string) => {
  const x = join(apps, a, rel)
  const y = join(apps, b, rel)
  if (!existsSync(y)) return
  expect([rel, files(x)]).toEqual([rel, files(y)])
  for (const f of files(x)) expect([`${a} vs ${b}: ${rel}/${f}`, readFileSync(join(x, f), "utf8") === readFileSync(join(y, f), "utf8")]).toEqual([`${a} vs ${b}: ${rel}/${f}`, true])
}

describe("vendored copies are identical", () => {
  test("interfaces in diffs, monaco and codemirror", () => {
    same("src/interfaces", "codemirror", "monaco")
    same("src/interfaces", "codemirror", "diffs")
  })
  test("shared editor code, strings and command script in monaco and codemirror", () => {
    same("src/shared", "codemirror", "monaco")
    same("strings", "codemirror", "monaco")
    same("test", "codemirror", "monaco")
    for (const f of ["src/main.ts", "src/l10n.ts", "build-web.ts", "notices.ts", "bunfig.toml", "web-src/index.html"]) {
      if (existsSync(join(apps, "monaco", f))) expect([f, readFileSync(join(apps, "codemirror", f), "utf8") === readFileSync(join(apps, "monaco", f), "utf8")]).toEqual([f, true])
    }
  })
})

describe("localization", () => {
  test("every t() key has English and Japanese strings", () => {
    const dir = join(import.meta.dir, "..")
    const en = JSON.parse(readFileSync(join(dir, "strings/en.json"), "utf8"))
    const ja = JSON.parse(readFileSync(join(dir, "strings/ja.json"), "utf8"))
    const calls = scanCalls(join(dir, "src"))
    for (const [key, english] of calls) {
      expect([key, en[key]]).toEqual([key, english])
      expect([key, typeof ja[key]]).toEqual([key, "string"])
    }
    expect(Object.keys(ja).sort()).toEqual(Object.keys(en).sort())
    expect(Object.keys(en).filter((k) => !calls.has(k))).toEqual([])
  })
})
