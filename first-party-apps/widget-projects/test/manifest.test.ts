// The store listing: manifest v2 caps every text field at 300 characters, and the host drops a
// package whose manifest breaks the schema without a word, so the App Store would show nothing.
import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

const manifest = JSON.parse(readFileSync(join(import.meta.dir, "../cmux-app.json"), "utf8")) as unknown
const MAX = 300

/** Every string in the manifest, with its JSON path. */
function strings(value: unknown, path = ""): Array<[string, string]> {
  if (typeof value === "string") return [[path || "/", value]]
  if (Array.isArray(value)) return value.flatMap((item, i) => strings(item, `${path}/${i}`))
  if (value && typeof value === "object") return Object.entries(value).flatMap(([k, v]) => strings(v, `${path}/${k}`))
  return []
}

describe("store listing", () => {
  test(`every text field fits the schema's ${MAX} characters`, () => {
    const over = strings(manifest).filter(([, text]) => text.length > MAX).map(([path, text]) => `${path} (${text.length})`)
    expect(over).toEqual([])
  })

  test("the listing has a description, an icon and 2-4 screenshots kept in the package", () => {
    const m = manifest as { description: string; icon: string; screenshots: string[] }
    expect(m.description.length).toBeGreaterThan(0)
    expect(m.icon).toBe("assets/icon.svg")
    expect(m.screenshots.length).toBeGreaterThanOrEqual(2)
    expect(m.screenshots.length).toBeLessThanOrEqual(4)
  })
})
