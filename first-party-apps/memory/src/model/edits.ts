// Memory edits as intents, so a stale edit can be made again on the new text
// (an agent may write the same file while the user reviews):
//   append  add a bullet (under a section when given, else at the end)
//   remove  delete the entry whose text matches
//   replace change the entry whose text matches
//   trash   move the whole file to the trash (origin user, through fs.trash)
// `applyIntent` returns the new text, or "gone" when the entry no longer exists.
// `toEdits` turns before/after into minimal line edits for document.edit.

import { diffLines, splitLines } from "./linediff.ts"
import { parseEntries } from "./entries.ts"

export type Intent =
  | { op: "append"; text: string; section?: string | null }
  | { op: "remove"; entry: string }
  | { op: "replace"; entry: string; text: string }
  | { op: "trash" }

export type IntentResult = { ok: true; text: string } | { ok: false; reason: "gone" | "empty" }

const clean = (s: string) => s.replace(/\s+/g, " ").trim()

export function applyIntent(text: string, intent: Intent): IntentResult {
  const lines = splitLines(text)
  const trailing = text === "" || text.endsWith("\n") ? "\n" : ""
  const join = (ls: string[]) => (ls.length ? ls.join("\n") + trailing : "")
  switch (intent.op) {
    case "trash":
      return { ok: true, text: "" }
    case "append": {
      const body = clean(intent.text)
      if (!body) return { ok: false, reason: "empty" }
      const line = `- ${body}`
      if (intent.section) {
        const entries = parseEntries(text).filter((e) => e.section === intent.section)
        const last = entries[entries.length - 1]
        if (last) return { ok: true, text: join([...lines.slice(0, last.end - 1), line, ...lines.slice(last.end - 1)]) }
      }
      const out = [...lines]
      while (out.length && out[out.length - 1]!.trim() === "") out.pop()
      const lastLine = out[out.length - 1] ?? ""
      if (out.length && !/^\s*(?:[-*+]|\d+[.)])\s+/.test(lastLine)) out.push("")
      out.push(line)
      return { ok: true, text: out.join("\n") + "\n" }
    }
    case "remove":
    case "replace": {
      const target = clean(intent.entry)
      const e = parseEntries(text).find((x) => clean(x.text) === target)
      if (!e) return { ok: false, reason: "gone" }
      if (intent.op === "remove") return { ok: true, text: join([...lines.slice(0, e.start - 1), ...lines.slice(e.end - 1)]) }
      const body = clean(intent.text)
      if (!body) return { ok: false, reason: "empty" }
      const prefix = /^(\s*(?:[-*+]|\d+[.)])\s+)/.exec(lines[e.start - 1]!)?.[1] ?? ""
      return { ok: true, text: join([...lines.slice(0, e.start - 1), `${prefix}${body}`, ...lines.slice(e.end - 1)]) }
    }
  }
}

/** One edit replaces lines [start, end) (1-based) with `lines`. Edits are sorted and do not overlap. */
export type LineEdit = { start: number; end: number; lines: string[] }

export function toEdits(before: string, after: string): LineEdit[] {
  const out: LineEdit[] = []
  let cur: LineEdit | null = null
  let oldNo = 1
  for (const l of diffLines(before, after)) {
    if (l.kind === "context") {
      if (cur) out.push(cur)
      cur = null
      oldNo++
      continue
    }
    cur ??= { start: oldNo, end: oldNo, lines: [] }
    if (l.kind === "del") {
      cur.end++
      oldNo++
    } else cur.lines.push(l.text)
  }
  if (cur) out.push(cur)
  return out
}

/** Applies edits to `text` (what the document host does); for tests and for the rebase check. */
export function applyEdits(text: string, edits: readonly LineEdit[]): string {
  const lines = splitLines(text)
  for (const e of [...edits].sort((a, b) => b.start - a.start)) lines.splice(e.start - 1, e.end - e.start, ...e.lines)
  return lines.length ? lines.join("\n") + "\n" : ""
}
