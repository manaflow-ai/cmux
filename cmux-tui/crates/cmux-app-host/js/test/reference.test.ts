import { describe, expect, test } from "bun:test"
import { referenceMarkdown } from "../../tools/gen-reference.ts"
import { generate } from "../../tools/gen-cmux-global.ts"

describe("generated docs reference", () => {
  test("escapes pipes and keeps one row per line", () => {
    const md = referenceMarkdown({
      apiVersion: "1.0.0",
      ops: { "a.b": { scope: "a:read", class: "read", docs: "line one\nline | two" } },
      never: ["x.close"],
      events: { "a.changed": { docs: "d", reads: "a.b", scope: "a:read" } },
      signals: { "a.b": { docs: "s", scopes: ["a:read"], push: [], pollFloorSeconds: 5, staleAfterSeconds: 60 } }
    })
    expect(md).toContain("| `a.b` | read | `a:read` | line one line \\| two |")
    expect(md).toContain("- `x.close`")
    expect(md).toContain("| `a.b` | `a:read` | nothing | 5 | 60 |")
  })

  test("the generated reference lists every op in scopes.json", () => {
    const files = generate()
    const scopes = JSON.parse(files["scopes.json"]!).ops as Record<string, unknown>
    const md = files["REFERENCE.md"]!
    for (const name of Object.keys(scopes)) expect(md).toContain(`| \`${name}\` |`)
  })
})

describe("merged schema directory", () => {
  test("small per-family files cover all three source kinds, with digests", () => {
    const files = generate()
    const rows = Object.entries(files).filter(([n]) => n.startsWith("../schema/merged/ops/"))
    expect(rows.length).toBeGreaterThan(20)
    const sources = new Set<string>()
    for (const [, body] of rows) {
      expect(body.length).toBeLessThan(200_000)
      for (const op of Object.values(JSON.parse(body).ops as Record<string, { source: string; digest: string }>)) {
        sources.add(op.source)
        expect(op.digest).toMatch(/^[0-9a-f]{16}$/)
      }
    }
    expect([...sources].sort()).toEqual(["app", "cloud", "local"])
    expect(JSON.parse(files["../schema/merged/index.json"]!).offeredActions.length).toBeGreaterThan(0)
  })
})
