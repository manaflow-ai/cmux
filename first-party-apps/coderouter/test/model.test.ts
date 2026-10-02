import { describe, expect, test } from "bun:test"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { JA, setLocale, t } from "../src/l10n.ts"
import { formatLatency, formatTokens, formatUsd, moveTo, recommend, relativeAge, shares, usageSummary, type Account, type Detected } from "../src/model.ts"
import { classify } from "../src/ops.ts"

const detected = (provider: string, status: Detected["status"], linkable = true): Detected => ({ provider, name: provider, status, linkable })
const account = (provider: string): Account => ({ id: `a_${provider}`, provider, name: provider, label: provider, state: "active", visibility: "private", mine: true })

describe("formatting", () => {
  test("tokens, dollars, latency", () => {
    expect([0, 999, 1000, 1843000, 12_480_000, 2.5e9].map(formatTokens)).toEqual(["0", "999", "1k", "1.8M", "12.5M", "2.5B"])
    expect([0, 0.004, 6.42, 1234.5].map(formatUsd)).toEqual(["$0", "<$0.01", "$6.42", "$1,235"])
    expect([412, 1530].map(formatLatency)).toEqual(["412 ms", "1.5 s"])
  })

  test("relative age", () => {
    const now = 1_000_000_000
    expect(relativeAge(null, now)).toBe("never used")
    expect(relativeAge(now - 5_000, now)).toBe("just now")
    expect(relativeAge(now - 7_200_000, now)).toBe("2 h ago")
  })

  test("usage summary", () => {
    expect(usageSummary(null)).toBe("No requests today")
    expect(usageSummary({ requests: 3, total_tokens: 1500, api_equivalent_usd: 0.2 })).toBe("1.5k tok · $0.20")
  })
})

describe("recommend", () => {
  test("signed-in, linkable, not connected, agent sign-ins first", () => {
    const list = [detected("openai", "signed_in"), detected("gemini", "signed_in", false), detected("claude", "signed_in"), detected("codex", "signed_in"), detected("anthropic", "missing"), detected("bedrock", "expired")]
    expect(recommend(list, [account("codex")]).map((d) => d.provider)).toEqual(["claude", "openai"])
  })
})

describe("routing order", () => {
  test("moveTo keeps every id once", () => {
    expect(moveTo(["a", "b", "c"], "c", 0)).toEqual(["c", "a", "b"])
    expect(moveTo(["a", "b", "c"], "a", 9)).toEqual(["b", "c", "a"])
    expect(moveTo(["a", "b"], "x", 0)).toEqual(["a", "b"])
  })

  test("usage bars scale to the largest row", () => {
    expect(shares([{ id: "1", label: "", requests: 1, total_tokens: 50, api_equivalent_usd: 0 }, { id: "2", label: "", requests: 1, total_tokens: 100, api_equivalent_usd: 0 }])).toEqual([0.5, 1])
  })
})

describe("errors", () => {
  test("map host codes to what the user sees", () => {
    expect(classify({ code: "operation.unsupported", message: "" }).kind).toBe("unsupported")
    expect(classify({ code: "scope.missing", message: "", details: { scope: "coderouter:read", op: "coderouter.status" } }).kind).toBe("scope")
    // The runtime's local refusal (no scope named) also covers ops this build does not know.
    expect(classify({ code: "scope.missing", message: "", details: { op: "coderouter.status" } }).kind).toBe("unsupported")
    expect(classify({ code: "auth.required", message: "" }).kind).toBe("signedOut")
    expect(classify({ code: "coderouter.unreachable", message: "" }).kind).toBe("unreachable")
    expect(classify(new Error("boom")).kind).toBe("other")
  })
})

describe("localization", () => {
  test("every key used in src has a Japanese entry", () => {
    const dir = join(import.meta.dir, "../src")
    const files = readdirSync(dir, { recursive: true }).map(String).filter((f) => f.endsWith(".ts"))
    const keys = new Set<string>()
    for (const f of files) for (const m of readFileSync(join(dir, f), "utf8").matchAll(/\bt\(\s*"([a-zA-Z0-9.]+)"/g)) keys.add(m[1]!)
    expect(keys.size).toBeGreaterThan(100)
    expect([...keys].filter((k) => !(k in JA))).toEqual([])
  })

  test("placeholders match between English and Japanese", () => {
    const dir = join(import.meta.dir, "../src")
    const holes = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(",")
    for (const f of readdirSync(dir, { recursive: true }).map(String).filter((f) => f.endsWith(".ts")))
      for (const m of readFileSync(join(dir, f), "utf8").matchAll(/\bt\(\s*"([a-zA-Z0-9.]+)",\s*"((?:[^"\\]|\\.)*)"/g)) expect(`${m[1]}:${holes(JA[m[1]!] ?? "")}`).toBe(`${m[1]}:${holes(m[2]!)}`)
    setLocale("ja")
    try {
      expect(t("checklist.left", "{n} left", { n: 3 })).toBe("残り 3")
      expect(t("wizard.counter", "Step {n} of {total}", { n: 2, total: 5 })).toBe("ステップ 2 / 5")
    } finally {
      setLocale("en")
    }
  })
})
