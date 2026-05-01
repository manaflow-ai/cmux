// Build a side-by-side row model from a parse-diff File.
//
// parse-diff gives us a flat sequence of normal/add/del changes per chunk.
// For side-by-side rendering we need to pair adjacent del+add runs into
// modified-line rows so we can show word-level highlighting between the
// matched (deleted, added) lines, and leave unpaired del/add as
// single-side rows.
import parseDiff, { type File, type Change } from "parse-diff"
import { diffWordsWithSpace } from "diff"

export type Side = "left" | "right" | "both"

export interface WordPart {
  text: string
  /** Highlight intensity:
   *  - "none"  → unchanged (or whole-line context)
   *  - "soft"  → entire add/del line, no intra-line emphasis
   *  - "hard"  → the actual changed token inside a modified line
   */
  emphasis: "none" | "soft" | "hard"
}

export type RowKind = "context" | "add" | "del" | "modify" | "hunk"

export interface DiffRow {
  kind: RowKind
  /** Old line number (1-based), or null for added lines/hunk markers. */
  oldLn: number | null
  /** New line number (1-based), or null for deleted lines/hunk markers. */
  newLn: number | null
  /** Left-side text+parts. Empty for pure add rows. */
  left: WordPart[] | null
  /** Right-side text+parts. Empty for pure del rows. */
  right: WordPart[] | null
  /** Hunk header text (when kind === "hunk"). */
  hunkHeader?: string
}

export interface DiffFile {
  path: string
  oldPath: string | null
  additions: number
  deletions: number
  isNew: boolean
  isDeleted: boolean
  rows: DiffRow[]
}

/** Pair adjacent del-runs and add-runs into modified rows. Leftover del/add
 *  become single-side rows. Normal changes pass through as context rows. */
function buildRowsForChunk(changes: Change[]): DiffRow[] {
  const rows: DiffRow[] = []
  let i = 0
  while (i < changes.length) {
    const c = changes[i]
    if (c.type === "normal") {
      rows.push({
        kind: "context",
        oldLn: c.ln1,
        newLn: c.ln2,
        left: [{ text: stripPrefix(c.content), emphasis: "none" }],
        right: [{ text: stripPrefix(c.content), emphasis: "none" }],
      })
      i++
      continue
    }

    // Collect a run of consecutive del then add changes.
    const dels: Change[] = []
    const adds: Change[] = []
    while (i < changes.length && changes[i].type === "del") {
      dels.push(changes[i])
      i++
    }
    while (i < changes.length && changes[i].type === "add") {
      adds.push(changes[i])
      i++
    }

    const paired = Math.min(dels.length, adds.length)
    for (let j = 0; j < paired; j++) {
      const d = dels[j] as Extract<Change, { type: "del" }>
      const a = adds[j] as Extract<Change, { type: "add" }>
      const dText = stripPrefix(d.content)
      const aText = stripPrefix(a.content)
      const { left, right } = wordDiff(dText, aText)
      rows.push({
        kind: "modify",
        oldLn: d.ln,
        newLn: a.ln,
        left,
        right,
      })
    }
    for (let j = paired; j < dels.length; j++) {
      const d = dels[j] as Extract<Change, { type: "del" }>
      rows.push({
        kind: "del",
        oldLn: d.ln,
        newLn: null,
        left: [{ text: stripPrefix(d.content), emphasis: "soft" }],
        right: null,
      })
    }
    for (let j = paired; j < adds.length; j++) {
      const a = adds[j] as Extract<Change, { type: "add" }>
      rows.push({
        kind: "add",
        oldLn: null,
        newLn: a.ln,
        left: null,
        right: [{ text: stripPrefix(a.content), emphasis: "soft" }],
      })
    }
  }
  return rows
}

/** parse-diff includes the leading +/-/space marker in `content`. Strip it. */
function stripPrefix(content: string): string {
  if (content.length === 0) return content
  const ch = content.charCodeAt(0)
  // 0x20 space, 0x2B '+', 0x2D '-', 0x5C '\' (e.g. "\ No newline at end of file")
  if (ch === 0x20 || ch === 0x2b || ch === 0x2d) return content.slice(1)
  return content
}

/** Run a word-level Myers diff between two strings and return paired
 *  per-side WordPart arrays. Tokens that match are "soft" (still on the
 *  changed-line background); tokens that differ are "hard" (emphasised). */
function wordDiff(oldText: string, newText: string): { left: WordPart[]; right: WordPart[] } {
  const parts = diffWordsWithSpace(oldText, newText)
  const left: WordPart[] = []
  const right: WordPart[] = []
  for (const p of parts) {
    if (p.added) {
      right.push({ text: p.value, emphasis: "hard" })
    } else if (p.removed) {
      left.push({ text: p.value, emphasis: "hard" })
    } else {
      left.push({ text: p.value, emphasis: "soft" })
      right.push({ text: p.value, emphasis: "soft" })
    }
  }
  if (left.length === 0) left.push({ text: "", emphasis: "soft" })
  if (right.length === 0) right.push({ text: "", emphasis: "soft" })
  return { left, right }
}

/** Pretty path: prefer `to` (post-rename), fall back to `from`, strip the
 *  leading `a/` or `b/` git prefix. */
function prettyPath(file: File): { path: string; oldPath: string | null } {
  const stripGit = (p?: string) => (p ? p.replace(/^[ab]\//, "") : "")
  const to = stripGit(file.to)
  const from = stripGit(file.from)
  const path = to && to !== "/dev/null" ? to : from || "(unknown)"
  const oldPath = from && from !== to && from !== "/dev/null" ? from : null
  return { path, oldPath }
}

export function parseUnifiedDiff(text: string): DiffFile[] {
  const files = parseDiff(text)
  const out: DiffFile[] = []
  for (const file of files) {
    const { path, oldPath } = prettyPath(file)
    const rows: DiffRow[] = []
    for (const chunk of file.chunks) {
      rows.push({
        kind: "hunk",
        oldLn: null,
        newLn: null,
        left: null,
        right: null,
        hunkHeader: chunk.content,
      })
      for (const r of buildRowsForChunk(chunk.changes)) rows.push(r)
    }
    out.push({
      path,
      oldPath,
      additions: file.additions,
      deletions: file.deletions,
      isNew: Boolean(file.new),
      isDeleted: Boolean(file.deleted),
      rows,
    })
  }
  return out
}
