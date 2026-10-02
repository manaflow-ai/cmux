// The harness's stand-in for the host palette ranker: case-insensitive,
// title first, then keywords, then subtitle; prefix > word start > substring
// > subsequence. It decides membership and order for snapshot scopes, so app
// tests can assert which rows a query shows. The macOS ranker scores
// differently (frecency, typo tolerance); tests should assert membership and
// the obvious first row, not fine ordering.

export interface Rankable {
  title: string
  subtitle?: string
  keywords?: string[]
}

function textScore(text: string, query: string): number {
  const t = text.toLowerCase()
  if (!t) return 0
  if (t.startsWith(query)) return 100
  const at = t.indexOf(query)
  if (at > 0) return /[\s\-_/.:]/.test(t[at - 1]!) ? 80 : 60
  let i = 0
  let first = -1
  for (let j = 0; j < t.length && i < query.length; j++) {
    if (t[j] === query[i]) {
      if (first < 0) first = j
      i++
    }
  }
  return i === query.length ? Math.max(1, 30 - first) : 0
}

/** Score of `item` for `query` (0: no match). An empty query matches everything with score 1. */
export function score(item: Rankable, query: string): number {
  const q = query.trim().toLowerCase()
  if (!q) return 1
  return Math.max(textScore(item.title, q), ...(item.keywords ?? []).map((k) => textScore(k, q) * 0.9), textScore(item.subtitle ?? "", q) * 0.5)
}

/** Filters and orders `items`: `fuzzy` by score then source order; `recency` and `source` keep the source order. */
export function rank<T extends Rankable>(items: readonly T[], query: string, ranking: "fuzzy" | "recency" | "source" = "fuzzy"): T[] {
  const scored = items.map((item, index) => ({ item, index, s: score(item, query) })).filter((x) => x.s > 0)
  if (ranking === "fuzzy") scored.sort((a, b) => b.s - a.s || a.index - b.index)
  return scored.map((x) => x.item)
}
