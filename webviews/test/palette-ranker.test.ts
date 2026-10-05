import { describe, expect, test } from "bun:test"
import { rankPalette, rankPaletteEmpty, type PaletteFrecency, type PaletteRankEntry } from "../src/palette/ranker"

const now = 800_000_000

function entry(id: string, title: string, options: Partial<PaletteRankEntry> = {}): PaletteRankEntry & { id: string } {
  return { id, title, ...options }
}

function rankedIDs(entries: readonly (PaletteRankEntry & { id: string })[], query: string, frecency: PaletteFrecency = {}) {
  return rankPalette({ entries, query, frecency, now }).flatMap((section) => section.rows.map((row) => entries[row.index].id))
}

describe("shared palette ranker", () => {
  test("ports the catalog queries from PaletteRankingTests", () => {
    const entries = [
      entry("action:splitRight", "Split Right"),
      entry("action:splitDown", "Split Down"),
      entry("action:closeTab", "Close Tab"),
      entry("action:newWindow", "New Window"),
      entry("action:toggleFullScreen", "Toggle Full Screen", { keywords: ["tfs"] }),
      entry("action:renameTab", "Rename Tab"),
      entry("action:newSurface", "New Surface"),
      entry("action:openSettings", "Open Settings", { keywords: ["preferences"] }),
    ]
    expect(rankedIDs(entries, "split r")[0]).toBe("action:splitRight")
    expect(rankedIDs(entries, "close tab")[0]).toBe("action:closeTab")
    expect(rankedIDs(entries, "new window")[0]).toBe("action:newWindow")
    expect(rankedIDs(entries, "tfs")[0]).toBe("action:toggleFullScreen")
    expect(rankedIDs(entries, "rename tab")[0]).toBe("action:renameTab")
    expect(rankedIDs(entries, "newSurface")[0]).toBe("action:newSurface")
    expect(rankedIDs(entries, "preferences")[0]).toBe("action:openSettings")
  })

  test("frecency breaks ties without beating a clearly better match", () => {
    const entries = [
      entry("right", "Split Right", { frecencyKey: "right" }),
      entry("down", "Split Down", { frecencyKey: "down" }),
      entry("folder", "Open Folder", { frecencyKey: "folder" }),
      entry("weak", "Buffer Scroll Load", { frecencyKey: "weak" }),
    ]
    const frecency: PaletteFrecency = { entries: {} }
    expect(rankedIDs(entries, "split", frecency)[0]).toBe("right")
    frecency.entries!.down = { score: 5, lastUsed: now }
    expect(rankedIDs(entries, "split", frecency)[0]).toBe("down")
    frecency.entries!.weak = { score: 1000, lastUsed: now }
    expect(rankedIDs(entries, "fold", frecency)[0]).toBe("folder")
  })

  test("frecency decays by its half-life and orders recent keys", () => {
    const store: PaletteFrecency = { entries: { a: { score: 2, lastUsed: now } }, halfLife: 100 }
    const score = (at: number) => store.entries!.a.score * 2 ** (-(at - store.entries!.a.lastUsed) / store.halfLife!)
    expect(Math.abs(score(now) - 2)).toBeLessThan(0.0001)
    expect(Math.abs(score(now + 100) - 1)).toBeLessThan(0.0001)
    expect(Math.abs(score(now + 200) - 0.5)).toBeLessThan(0.0001)
    store.entries!.b = { score: 1, lastUsed: now + 200 }
    const top = Object.keys(store.entries!).sort((left, right) => {
      const l = store.entries![left]
      const r = store.entries![right]
      return r.score * 2 ** (-(now + 200 - r.lastUsed) / store.halfLife!) - l.score * 2 ** (-(now + 200 - l.lastUsed) / store.halfLife!)
    })
    expect(top).toEqual(["b", "a"])
  })

  test("incremental queries and a fresh scan return the same rows", () => {
    const entries = [entry("right", "Split Right"), entry("down", "Split Down"), entry("other", "Open Folder")]
    rankPalette({ entries, query: "s", now })
    rankPalette({ entries, query: "sp", now })
    const narrowed = rankedIDs(entries, "spl r")
    const fresh = rankedIDs(entries, "spl r")
    expect(narrowed).toEqual(fresh)
    expect(narrowed.length).toBeGreaterThan(0)
    expect(rankedIDs(entries, "sp")).toEqual(rankedIDs(entries, "sp"))
  })

  test("empty query shows recent first, then ordered visible sections", () => {
    const entries = [
      entry("settings", "Open Settings", { sectionIndex: 0, frecencyKey: "settings" }),
      entry("splitDown", "Split Down", { sectionIndex: 0, frecencyKey: "splitDown" }),
      entry("workspace", "api server", { sectionIndex: 1, isVisibleWhenQueryEmpty: false, frecencyKey: "workspace" }),
    ]
    const result = rankPaletteEmpty({
      entries,
      sectionOrders: [0, 10],
      frecency: { entries: { splitDown: { score: 1, lastUsed: now } } },
      now,
      showsRecent: true,
    })
    expect(result[0]?.sectionIndex).toBeNull()
    expect(result[0]?.rows.map((row) => entries[row.index].id)).toEqual(["splitDown"])
    const all = result.flatMap((section) => section.rows.map((row) => entries[row.index].id))
    expect(all).toEqual(["splitDown", "settings"])
    expect(new Set(all).size).toBe(all.length)
    expect(rankedIDs(entries, "api")).toContain("workspace")
  })

  test("disabled rows remain visible below enabled matches and highlights use scalar offsets", () => {
    const entries = [
      entry("enabled", "Split Right"),
      entry("disabled", "Split Down", { isEnabled: false }),
    ]
    const result = rankPalette({ entries, query: "split", now, highlightLimit: 1 })
    expect(result[0]?.rows.map((row) => entries[row.index].id)).toEqual(["enabled", "disabled"])
    expect(result[0]?.rows[0]?.highlights).toEqual([0, 1, 2, 3, 4])
    expect(result[0]?.rows[1]?.highlights).toEqual([])
  })

  test("the checked-in JavaScriptCore bridge exposes the same ranker", async () => {
    const bundle = await Bun.file("../Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js").text()
    new Function(bundle)()
    const bridge = (globalThis as typeof globalThis & { __cmuxPaletteRank?: (request: string) => string }).__cmuxPaletteRank
    expect(typeof bridge).toBe("function")
    const sections = JSON.parse(bridge!(JSON.stringify({
      operation: "rank",
      entries: [entry("right", "Split Right"), entry("down", "Split Down")],
      query: "split r",
      sectionOrders: [],
      frecency: { entries: {} },
      now,
      showsRecent: false,
      keepsSectionOrder: false,
      ranksPrefixFirst: false,
      recentLimit: 5,
      rowLimit: 400,
      highlightLimit: 60,
    }))) as Array<{ rows: Array<{ index: number }> }>
    expect(sections[0]?.rows[0]?.index).toBe(0)
  })
})
