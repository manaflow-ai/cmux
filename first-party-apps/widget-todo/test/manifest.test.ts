// The store listing: the host drops a package whose manifest has any text over the v2 schema's
// 300-character cap, and the store then shows nothing for the app.
import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

const manifest = JSON.parse(readFileSync(join(import.meta.dir, "..", "cmux-app.json"), "utf8"))

function strings(value: unknown, path: string, out: Array<[string, string]>) {
  if (typeof value === "string") out.push([path, value])
  else if (Array.isArray(value)) value.forEach((v, i) => strings(v, `${path}[${i}]`, out))
  else if (value && typeof value === "object") for (const [k, v] of Object.entries(value)) strings(v, path ? `${path}.${k}` : k, out)
  return out
}

test("every manifest text, in every language, fits the 300-character cap", () => {
  const over = strings(manifest, "", []).filter(([, s]) => [...s].length > 300).map(([p, s]) => `${p} (${[...s].length})`)
  expect(over).toEqual([])
})

test("the listing has a description for people in each language, and an icon and screenshots in the package", () => {
  expect(Object.keys(manifest.description)).toEqual(expect.arrayContaining(["en", "ja"]))
  expect(manifest.icon).toBe("assets/icon.svg")
  expect(manifest.screenshots.length).toBeGreaterThanOrEqual(2)
  for (const file of [manifest.icon, ...manifest.screenshots]) expect(() => readFileSync(join(import.meta.dir, "..", file))).not.toThrow()
})
