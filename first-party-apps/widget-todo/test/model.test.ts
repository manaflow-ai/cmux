import { describe, expect, test } from "bun:test"
import { readFileSync, readdirSync } from "node:fs"
import { join } from "node:path"
import { cleanText, merge, newer, split, type Item } from "../src/model.ts"

const at = (id: string, updated: number, change: Partial<Item> = {}): Item => ({ id, text: id, done: false, created: 1, updated, by: "x", ...change })

describe("merge", () => {
  test("per item, the newer version wins; a tie goes to the larger device id, the same on both sides", () => {
    expect(newer(at("a", 2), at("a", 3, { done: true })).done).toBe(true)
    const left = at("a", 5, { by: "b", text: "left" })
    const right = at("a", 5, { by: "c", text: "right" })
    expect(newer(left, right).text).toBe("right")
    expect(newer(right, left).text).toBe("right")
  })

  test("items only one side has are kept; a newer tombstone removes the item", () => {
    const merged = merge([at("a", 1), at("b", 1)], [at("b", 2, { deleted: true }), at("c", 1)])
    expect([...merged.keys()].sort()).toEqual(["a", "b", "c"])
    expect(split(merged.values()).open.map((i) => i.id)).toEqual(["a", "c"])
  })
})

describe("split", () => {
  test("open items oldest first, done ones latest first, and a just-checked item stays open until it settles", () => {
    const items = [at("b", 1, { created: 2 }), at("a", 1, { created: 1 }), at("c", 1, { created: 3, done: true, doneAt: 5 }), at("d", 1, { created: 4, done: true, doneAt: 9 })]
    expect(split(items).open.map((i) => i.id)).toEqual(["a", "b"])
    expect(split(items).done.map((i) => i.id)).toEqual(["d", "c"])
    const settling = split(items, new Set(["d"]))
    expect(settling.open.map((i) => i.id)).toEqual(["a", "b", "d"])
    expect(settling.remaining).toBe(2)
  })
})

test("cleanText trims, folds whitespace and refuses empty text", () => {
  expect(cleanText("  a \n b ")).toBe("a b")
  expect(cleanText("   ")).toBeNull()
  expect(cleanText("x".repeat(900))!.length).toBe(500)
})

describe("strings", () => {
  const dir = join(import.meta.dir, "..")
  const used = new Map<string, string>()
  for (const file of readdirSync(join(dir, "src"))) {
    for (const m of readFileSync(join(dir, "src", file), "utf8").matchAll(/\bt\("([^"]+)", "([^"]*)"/g)) used.set(m[1]!, m[2]!)
  }
  const table = (lang: string) => JSON.parse(readFileSync(join(dir, `strings/${lang}.json`), "utf8")) as Record<string, string>
  const holes = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()

  test("strings/en.json is exactly the English of every t() call", () => {
    expect(table("en")).toEqual(Object.fromEntries([...used.entries()].sort(([a], [b]) => a.localeCompare(b))))
  })

  test("strings/ja.json has every key with the same placeholders", () => {
    const ja = table("ja")
    expect(Object.keys(ja).sort()).toEqual([...used.keys()].sort())
    for (const [key, english] of used) expect([key, holes(ja[key]!)]).toEqual([key, holes(english)])
  })
})
