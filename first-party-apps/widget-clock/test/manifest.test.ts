// The store listing: cmux drops a package whose manifest does not validate (a text over 300
// characters, an unknown field) without a word, and the App Store then shows nothing.
import { describe, expect, test } from "bun:test"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { manifestSchema, SchemaValidator } from "cmux-extension-sdk/testing"

const dir = join(import.meta.dir, "..")
const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))

/** Every string in a localized text field ({en: ...} or a plain string), with its path. */
function texts(value: unknown, path: string): Array<[string, string]> {
  if (typeof value === "string") return [[path, value]]
  if (value && typeof value === "object" && !Array.isArray(value))
    return Object.entries(value).flatMap(([key, v]) => texts(v, `${path}/${key}`))
  return []
}

describe("store listing", () => {
  test("the manifest is a valid v2 package", () => {
    expect(new SchemaValidator(manifestSchema()).validate(manifest)).toEqual([])
  })

  test("every text field is at most 300 characters", () => {
    const fields = [
      ...texts(manifest.name, "/name"),
      ...texts(manifest.description, "/description"),
      ...texts(manifest.tagline, "/tagline"),
      ...Object.entries(manifest.implements ?? {}).flatMap(([name, impl]) => texts((impl as { title?: unknown }).title, `/implements/${name}/title`)),
      ...Object.entries(manifest.settings?.properties ?? {}).flatMap(([key, prop]) => [
        ...texts((prop as { title?: unknown }).title, `/settings/${key}/title`),
        ...texts((prop as { description?: unknown }).description, `/settings/${key}/description`)
      ])
    ]
    expect(fields.length).toBeGreaterThan(3)
    expect(fields.filter(([, text]) => text.length > 300)).toEqual([])
  })

  test("not bundled, listed in the store, with its icon and screenshots in the package", () => {
    expect(existsSync(join(dir, "BUNDLED"))).toBe(false)
    expect(existsSync(join(dir, "STORE"))).toBe(true)
    for (const path of [manifest.icon, ...manifest.screenshots]) expect(existsSync(join(dir, path))).toBe(true)
    expect(manifest.screenshots.length).toBeGreaterThanOrEqual(2)
    expect(manifest.implements["cmux.widget/1"].options.places).toEqual(["newtab", "sidebar"])
  })
})
