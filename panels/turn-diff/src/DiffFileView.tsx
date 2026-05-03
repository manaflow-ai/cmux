import React, { useMemo } from "react"
import type { DiffFile, DiffRow, WordPart } from "./diffModel"
import { detectLanguage, tokenizeLine } from "./highlighter"

interface Props {
  file: DiffFile
  expanded: boolean
  onToggle: (path: string) => void
  unified: boolean
}

export function DiffFileView({ file, expanded, onToggle, unified }: Props) {
  const lang = useMemo(() => detectLanguage(file.path), [file.path])

  const status = file.isNew ? "added" : file.isDeleted ? "deleted" : "modified"

  return (
    <section className="file" data-status={status} data-expanded={expanded}>
      <button
        className="file-header"
        onClick={() => onToggle(file.path)}
        aria-expanded={expanded}
      >
        <span className={`twisty ${expanded ? "open" : "closed"}`} aria-hidden>
          ▾
        </span>
        <span className="file-path">
          {file.oldPath ? (
            <>
              <span className="old-path">{file.oldPath}</span>
              <span className="rename-arrow"> → </span>
            </>
          ) : null}
          {file.path}
        </span>
        {file.isNew ? <span className="file-tag new">new</span> : null}
        {file.isDeleted ? <span className="file-tag deleted">deleted</span> : null}
        <span className="file-counts">
          <span className="add-badge">+{file.additions}</span>
          <span className="del-badge">−{file.deletions}</span>
        </span>
      </button>
      {expanded ? (
        unified ? (
          <UnifiedDiffView rows={file.rows} lang={lang} />
        ) : (
          <SideBySideDiffView rows={file.rows} lang={lang} />
        )
      ) : null}
    </section>
  )
}

// ---------- Side-by-side (wide) renderer ---------------------------------

interface ViewProps {
  rows: DiffRow[]
  lang: string | null
}

function SideBySideDiffView({ rows, lang }: ViewProps) {
  return (
    <div className="file-body side-by-side" role="table">
      {rows.map((row, idx) => (
        <SideBySideRow key={idx} row={row} lang={lang} />
      ))}
    </div>
  )
}

const SideBySideRow = React.memo(function SideBySideRow({ row, lang }: { row: DiffRow; lang: string | null }) {
  if (row.kind === "hunk") {
    return (
      <div className="row hunk" role="row">
        <div className="gutter old hunk-gutter" />
        <div className="cell hunk-cell">{row.hunkHeader}</div>
      </div>
    )
  }

  return (
    <div className={`row ${row.kind}`} role="row">
      <div className="gutter old">{row.oldLn ?? ""}</div>
      <div className={`cell left side-${cellSide(row.kind, "left")}`}>
        <LineContent parts={row.left} lang={lang} />
      </div>
      <div className="gutter new">{row.newLn ?? ""}</div>
      <div className={`cell right side-${cellSide(row.kind, "right")}`}>
        <LineContent parts={row.right} lang={lang} />
      </div>
    </div>
  )
})

function cellSide(kind: DiffRow["kind"], side: "left" | "right"): string {
  if (kind === "context") return "context"
  if (kind === "del") return side === "left" ? "del" : "empty"
  if (kind === "add") return side === "right" ? "add" : "empty"
  if (kind === "modify") return side === "left" ? "del" : "add"
  return "context"
}

// ---------- Unified (narrow) renderer ------------------------------------

function UnifiedDiffView({ rows, lang }: ViewProps) {
  // A "modify" row in the row model represents a paired delete+add line with
  // word-level diff parts already computed. For the unified view we want to
  // emit it as two separate physical rows (one red, one green) so the user
  // sees one column per change, while keeping the same word-level emphasis.
  const flat = useMemo(() => flattenForUnified(rows), [rows])
  return (
    <div className="file-body unified" role="table">
      {flat.map((row, idx) => (
        <UnifiedRow key={idx} row={row} lang={lang} />
      ))}
    </div>
  )
}

interface UnifiedPhysicalRow {
  kind: "context" | "add" | "del" | "hunk"
  lineNo: number | null
  parts: WordPart[] | null
  hunkHeader?: string
}

function flattenForUnified(rows: DiffRow[]): UnifiedPhysicalRow[] {
  const out: UnifiedPhysicalRow[] = []
  for (const r of rows) {
    if (r.kind === "hunk") {
      out.push({ kind: "hunk", lineNo: null, parts: null, hunkHeader: r.hunkHeader })
      continue
    }
    if (r.kind === "context") {
      out.push({ kind: "context", lineNo: r.newLn ?? r.oldLn, parts: r.left })
      continue
    }
    if (r.kind === "del") {
      out.push({ kind: "del", lineNo: r.oldLn, parts: r.left })
      continue
    }
    if (r.kind === "add") {
      out.push({ kind: "add", lineNo: r.newLn, parts: r.right })
      continue
    }
    if (r.kind === "modify") {
      // Emit deleted side first, then added side. Word-level parts already
      // carry "hard" emphasis on the differing tokens.
      out.push({ kind: "del", lineNo: r.oldLn, parts: r.left })
      out.push({ kind: "add", lineNo: r.newLn, parts: r.right })
    }
  }
  return out
}

const UnifiedRow = React.memo(function UnifiedRow({ row, lang }: { row: UnifiedPhysicalRow; lang: string | null }) {
  if (row.kind === "hunk") {
    return (
      <div className="unified-diff-row hunk" role="row">
        <div className="unified-gutter hunk-gutter" />
        <div className="unified-lineno hunk-gutter" />
        <div className="unified-content hunk-cell">{row.hunkHeader}</div>
      </div>
    )
  }

  const sym = row.kind === "add" ? "+" : row.kind === "del" ? "−" : " "
  return (
    <div className={`unified-diff-row ${row.kind}`} role="row">
      <div className="unified-gutter" aria-hidden>{sym}</div>
      <div className="unified-lineno">{row.lineNo ?? ""}</div>
      <div className={`unified-content side-${row.kind}`}>
        <LineContent parts={row.parts} lang={lang} />
      </div>
    </div>
  )
})

// ---------- Shared line content ------------------------------------------

interface LineContentProps {
  parts: WordPart[] | null
  lang: string | null
}

function LineContent({ parts, lang }: LineContentProps) {
  if (!parts) return <span className="line-content empty-line" />

  // Concatenate text for syntax highlighting, then walk shiki tokens in
  // lockstep with our word-diff parts so we keep BOTH layers: theme color
  // for the character, and "hard"/"soft" emphasis class on the wrapping span.
  const fullText = parts.map((p) => p.text).join("")
  const synTokens = tokenizeLine(fullText, lang)

  const out: React.ReactNode[] = []
  let synIdx = 0
  let synOffset = 0
  let key = 0

  for (const part of parts) {
    let remaining = part.text.length
    while (remaining > 0 && synIdx < synTokens.length) {
      const tok = synTokens[synIdx]
      const available = tok.text.length - synOffset
      const take = Math.min(remaining, available)
      const chunk = tok.text.slice(synOffset, synOffset + take)
      out.push(
        <span
          key={key++}
          className={emphasisClass(part.emphasis)}
          style={tok.color ? { color: tok.color } : undefined}
        >
          {chunk}
        </span>
      )
      synOffset += take
      remaining -= take
      if (synOffset >= tok.text.length) {
        synIdx++
        synOffset = 0
      }
    }
    // Tail (e.g. trailing whitespace not in any shiki token, or fallback path).
    if (remaining > 0) {
      out.push(
        <span key={key++} className={emphasisClass(part.emphasis)}>
          {part.text.slice(part.text.length - remaining)}
        </span>
      )
    }
  }

  return <span className="line-content">{out}</span>
}

function emphasisClass(e: WordPart["emphasis"]): string {
  if (e === "hard") return "tok-hard"
  if (e === "soft") return "tok-soft"
  return "tok-none"
}
