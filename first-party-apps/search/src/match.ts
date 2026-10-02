// Matching and snippets: pure functions over strings. Offsets are UTF-16 code
// units (JavaScript string indexes), the unit every proposed op returns.

import type { ParsedQuery } from "./query.ts"

export interface Range {
  start: number
  length: number
}

/** A preview cut around one match: `before` + `match` + `after` is the shown text. */
export interface Segments {
  before: string
  match: string
  after: string
}

export interface NameMatch {
  /** 0..100: exact 100, prefix 90, word start 80, substring 70, all words 60, fuzzy 20..55, regex 65. */
  quality: number
  range: Range | null
}

export interface Matcher {
  readonly query: ParsedQuery
  /** First match in a body of text (terminal line, file line, page text). */
  find(text: string): Range | null
  /** Match quality against a short name (workspace, tab title, path). */
  name(text: string): NameMatch | null
}

const fold = (s: string, caseSensitive: boolean) => (caseSensitive ? s : s.toLowerCase())
const isWordChar = (c: string | undefined) => !!c && /[\p{L}\p{N}_]/u.test(c)

export function compile(query: ParsedQuery): Matcher {
  const text = query.text
  const empty = !text || !!query.error
  const re = query.regex && !empty ? new RegExp(text, query.caseSensitive ? "" : "i") : null
  const needle = fold(text, query.caseSensitive)
  const words = needle.split(/\s+/).filter(Boolean)

  const find = (hay: string): Range | null => {
    if (empty || !hay) return null
    if (re) {
      const m = re.exec(hay)
      return m && m[0].length > 0 ? { start: m.index, length: m[0].length } : null
    }
    const at = fold(hay, query.caseSensitive).indexOf(needle)
    return at < 0 ? null : { start: at, length: text.length }
  }

  const name = (hay: string): NameMatch | null => {
    if (empty || !hay) return null
    if (re) {
      const r = find(hay)
      return r ? { quality: 65, range: r } : null
    }
    const h = fold(hay, query.caseSensitive)
    if (h === needle) return { quality: 100, range: { start: 0, length: hay.length } }
    const at = h.indexOf(needle)
    if (at === 0) return { quality: 90, range: { start: 0, length: text.length } }
    if (at > 0) return { quality: isWordChar(h[at - 1]) ? 70 : 80, range: { start: at, length: text.length } }
    if (query.exact) return null
    if (words.length > 1 && words.every((w) => h.includes(w))) return { quality: 60, range: { start: h.indexOf(words[0]!), length: words[0]!.length } }
    return fuzzy(needle.replace(/\s+/g, ""), h)
  }

  return { query, find, name }
}

/**
 * Subsequence match for short names: every query character in order. Rewards
 * consecutive runs and characters at word starts; needs at least two
 * characters so one letter never matches everything.
 */
export function fuzzy(needle: string, hay: string): NameMatch | null {
  if (needle.length < 2) return null
  let score = 0
  let run = 0
  let first = -1
  let last = -1
  let j = 0
  for (let i = 0; i < hay.length && j < needle.length; i++) {
    if (hay[i] !== needle[j]) {
      run = 0
      continue
    }
    if (first < 0) first = i
    run++
    score += run > 1 ? 3 : 1
    if (i === 0 || !isWordChar(hay[i - 1])) score += 2
    last = i
    j++
  }
  if (j < needle.length) return null
  const spread = last - first + 1 - needle.length
  const quality = Math.max(20, Math.min(55, 20 + Math.round((score / (needle.length * 3)) * 35) - Math.min(15, spread)))
  return { quality, range: null }
}

/** Collapses runs of whitespace so a terminal or file line reads as one line. */
const squash = (s: string) => s.replace(/\s+/g, " ")

/**
 * Cuts `text` around `range`, keeping at most `radius` characters on each
 * side, with an ellipsis where text was cut.
 */
export function snippet(text: string, range: Range | null, radius = 60): Segments {
  if (!range) {
    const flat = squash(text).trim()
    return { before: flat.length > radius * 2 ? `${flat.slice(0, radius * 2)}…` : flat, match: "", after: "" }
  }
  const end = range.start + range.length
  const from = Math.max(0, range.start - radius)
  const to = Math.min(text.length, end + radius)
  const before = squash(text.slice(from, range.start)).trimStart()
  const after = squash(text.slice(end, to)).trimEnd()
  return { before: (from > 0 ? "…" : "") + before, match: squash(text.slice(range.start, end)), after: after + (to < text.length ? "…" : "") }
}

export const joinSegments = (s: Segments) => s.before + s.match + s.after

/** Segments for a short name with a highlighted range (no cutting). */
export function nameSegments(text: string, range: Range | null): Segments {
  if (!range) return { before: text, match: "", after: "" }
  return { before: text.slice(0, range.start), match: text.slice(range.start, range.start + range.length), after: text.slice(range.start + range.length) }
}
