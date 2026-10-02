// Pure helpers: body edits by line, markdown files for export and import,
// ages. No cmux globals here, so tests import this module directly. Titles,
// previews, search, order and limits belong to the notes server.

import type { Note, TextEdit } from "./notes.ts"

export const normalizeNewlines = (s: string) => s.replace(/\r\n?/g, "\n")

/** UTF-16 offsets of line `index` (without its newline), or null when it does not exist. */
export function lineRange(body: string, index: number): { start: number; end: number } | null {
  if (!Number.isInteger(index) || index < 0) return null
  let start = 0
  for (let i = 0; i < index; i++) {
    const nl = body.indexOf("\n", start)
    if (nl < 0) return null
    start = nl + 1
  }
  const nl = body.indexOf("\n", start)
  return { start, end: nl < 0 ? body.length : nl }
}

const CHECK = /^(\s*[-*+]\s+\[)([ xX])(\]\s?)/

/** "- [ ] task" <-> "- [x] task"; other lines are returned unchanged. */
export function toggleCheckLine(line: string): string {
  const m = line.match(CHECK)
  if (!m) return line
  return `${m[1]}${m[2] === " " ? "x" : " "}${m[3]}${line.slice(m[0].length)}`
}

/** The one-character edit that toggles the checkbox on line `index`, or null when that line has none. */
export function toggleEdit(body: string, index: number): TextEdit | null {
  const r = lineRange(body, index)
  if (!r) return null
  const m = body.slice(r.start, r.end).match(CHECK)
  if (!m) return null
  const at = r.start + m[1]!.length
  return { start: at, end: at + 1, text: m[2] === " " ? "x" : " " }
}

/**
 * Where line `index` of an older body (whose text was `text`) is in a newer
 * body: the same index when it still holds that text, else the nearest line
 * with exactly that text; null when the line is gone or ambiguous.
 */
export function rebaseLine(body: string, index: number, text: string): number | null {
  const lines = body.split("\n")
  if (lines[index] === text) return index
  const hits = lines.flatMap((l, i) => (l === text ? [i] : []))
  if (hits.length === 0) return null
  const best = hits.sort((a, b) => Math.abs(a - index) - Math.abs(b - index))
  return best.length > 1 && Math.abs(best[0]! - index) === Math.abs(best[1]! - index) ? null : best[0]!
}

/** Applies non-overlapping edits (offsets of `body`). */
export function applyEdits(body: string, edits: readonly TextEdit[]): string {
  let out = body
  for (const e of [...edits].sort((a, b) => b.start - a.start)) out = out.slice(0, e.start) + e.text + out.slice(e.end)
  return out
}

/** File name for export: a slug of the title (letters of any script kept), ".md". */
export function fileNameOf(note: Pick<Note, "title">, fallback = "note"): string {
  const slug = note.title
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48)
    .replace(/-+$/, "")
  return `${slug || fallback}.md`
}

/** One unique file name per note, in order ("ideas.md", "ideas-2.md"). */
export function uniqueFileNames(notes: ReadonlyArray<Pick<Note, "title">>): string[] {
  const used = new Set<string>()
  return notes.map((n) => {
    const base = fileNameOf(n)
    let name = base
    for (let i = 2; used.has(name); i++) name = base.replace(/\.md$/, `-${i}.md`)
    used.add(name)
    return name
  })
}

const HEADING = /^\s{0,3}#\s+(.*?)\s*#*\s*$/

/** Markdown for export: a level-1 heading with the explicit title unless the body already starts with it. */
export function toMarkdown(note: Pick<Note, "title" | "title_explicit" | "body">): string {
  const body = note.body.replace(/\s+$/, "")
  if (!note.title_explicit || !note.title.trim()) return `${body}\n`
  const first = body.split("\n", 1)[0] ?? ""
  if (first.match(HEADING)?.[1] === note.title.trim()) return `${body}\n`
  return body ? `# ${note.title.trim()}\n\n${body}\n` : `# ${note.title.trim()}\n`
}

/**
 * A note from an imported markdown file: a leading level-1 heading becomes the
 * explicit title (the inverse of toMarkdown); otherwise the server derives one.
 */
export function fromMarkdown(text: string): { title?: string; body: string } {
  const lines = normalizeNewlines(text.replace(/^﻿/, "")).replace(/\s+$/, "").split("\n")
  while (lines.length && !lines[0]!.trim()) lines.shift()
  const heading = lines[0]?.match(HEADING)
  if (!heading?.[1]) return { body: lines.join("\n") }
  lines.shift()
  while (lines.length && !lines[0]!.trim()) lines.shift()
  return { title: heading[1], body: lines.join("\n") }
}
