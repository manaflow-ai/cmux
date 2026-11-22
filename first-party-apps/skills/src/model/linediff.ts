// Line diff (LCS) and unified patch text. Config files and SKILL.md files
// are small, so the quadratic table is fine; inputs above MAX_CELLS fall back
// to "replace everything" instead of allocating a huge table.

export type DiffLine = { kind: "context" | "add" | "del"; text: string; oldLine: number | null; newLine: number | null }

const MAX_CELLS = 4_000_000

export const splitLines = (text: string): string[] => (text === "" ? [] : text.replace(/\n$/, "").split("\n"))

export function diffLines(before: string, after: string): DiffLine[] {
  const a = splitLines(before), b = splitLines(after)
  const n = a.length, m = b.length
  if (n * m > MAX_CELLS) {
    return [...a.map((text, i): DiffLine => ({ kind: "del", text, oldLine: i + 1, newLine: null })), ...b.map((text, j): DiffLine => ({ kind: "add", text, oldLine: null, newLine: j + 1 }))]
  }
  const lcs: Uint32Array[] = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1))
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) lcs[i]![j] = a[i] === b[j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!)
  const out: DiffLine[] = []
  let i = 0, j = 0
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) out.push({ kind: "context", text: a[i]!, oldLine: ++i, newLine: ++j })
    else if (i < n && (j >= m || lcs[i + 1]![j]! >= lcs[i]![j + 1]!)) out.push({ kind: "del", text: a[i]!, oldLine: ++i, newLine: null })
    else out.push({ kind: "add", text: b[j]!, oldLine: null, newLine: ++j })
  }
  return out
}

/** Unified patch with `context` lines around each change. Empty when nothing changed. */
export function unifiedPatch(path: string, before: string, after: string, context = 3): string {
  const lines = diffLines(before, after)
  const changed = lines.map((l, k) => (l.kind === "context" ? -1 : k)).filter((k) => k >= 0)
  if (!changed.length) return ""
  const hunks: Array<[number, number]> = []
  for (const k of changed) {
    const lo = Math.max(0, k - context), hi = Math.min(lines.length - 1, k + context)
    const last = hunks[hunks.length - 1]
    if (last && lo <= last[1] + 1) last[1] = Math.max(last[1], hi)
    else hunks.push([lo, hi])
  }
  const out = [`--- a/${path}`, `+++ b/${path}`]
  for (const [lo, hi] of hunks) {
    const slice = lines.slice(lo, hi + 1)
    const oldStart = slice.find((l) => l.oldLine !== null)?.oldLine ?? (lines.slice(0, lo).filter((l) => l.oldLine !== null).length)
    const newStart = slice.find((l) => l.newLine !== null)?.newLine ?? (lines.slice(0, lo).filter((l) => l.newLine !== null).length)
    const oldCount = slice.filter((l) => l.kind !== "add").length, newCount = slice.filter((l) => l.kind !== "del").length
    out.push(`@@ -${oldStart},${oldCount} +${newStart},${newCount} @@`)
    for (const l of slice) out.push(`${l.kind === "add" ? "+" : l.kind === "del" ? "-" : " "}${l.text}`)
  }
  return out.join("\n") + "\n"
}
