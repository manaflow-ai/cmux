// Line diff of two texts (Myers, O((N+M)D)), grouped into hunks with context.
// Used when a producer gives two texts instead of a patch (documents input).

import { hunkId, type DiffLine, type FileDiff, type Hunk } from "./unified.ts"

export type Op = { kind: "context" | "add" | "del"; oldIndex: number; newIndex: number }

/** Edit script from a to b. Falls back to delete-all/insert-all past `maxCost` edits. */
export function diffLines(a: readonly string[], b: readonly string[], maxCost = 4000): Op[] {
  const n = a.length
  const m = b.length
  const max = n + m
  const offset = max + 1
  const v = new Int32Array(2 * max + 3)
  const trace: Int32Array[] = []
  let found = false
  for (let d = 0; d <= Math.min(max, maxCost); d++) {
    trace.push(v.slice())
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && v[offset + k - 1]! < v[offset + k + 1]!) ? v[offset + k + 1]! : v[offset + k - 1]! + 1
      let y = x - k
      while (x < n && y < m && a[x] === b[y]) {
        x++
        y++
      }
      v[offset + k] = x
      if (x >= n && y >= m) {
        found = true
        break
      }
    }
    if (found) break
  }
  if (!found) {
    return [
      ...a.map((_, i): Op => ({ kind: "del", oldIndex: i, newIndex: -1 })),
      ...b.map((_, j): Op => ({ kind: "add", oldIndex: -1, newIndex: j }))
    ]
  }
  // Backtrack.
  const ops: Op[] = []
  let x = n
  let y = m
  for (let d = trace.length - 1; d >= 0; d--) {
    const vd = trace[d]!
    const k = x - y
    const prevK = k === -d || (k !== d && vd[offset + k - 1]! < vd[offset + k + 1]!) ? k + 1 : k - 1
    const prevX = d === 0 ? 0 : vd[offset + prevK]!
    const prevY = prevX - prevK
    while (x > prevX && y > prevY) {
      x--
      y--
      ops.push({ kind: "context", oldIndex: x, newIndex: y })
    }
    if (d > 0) {
      if (x === prevX) ops.push({ kind: "add", oldIndex: -1, newIndex: prevY })
      else ops.push({ kind: "del", oldIndex: prevX, newIndex: -1 })
    }
    x = prevX
    y = prevY
  }
  return ops.reverse()
}

export const splitLines = (text: string): string[] => {
  if (text === "") return []
  const lines = text.replace(/\r\n/g, "\n").split("\n")
  if (lines.at(-1) === "") lines.pop()
  return lines
}

/** Groups an edit script into hunks with `context` unchanged lines around each change. */
export function toHunks(path: string, a: readonly string[], b: readonly string[], ops: readonly Op[], context = 3): Hunk[] {
  const changeAt = ops.map((o, i) => (o.kind === "context" ? -1 : i)).filter((i) => i >= 0)
  if (!changeAt.length) return []
  const ranges: Array<[number, number]> = []
  for (const i of changeAt) {
    const from = Math.max(0, i - context)
    const to = Math.min(ops.length - 1, i + context)
    const last = ranges.at(-1)
    if (last && from <= last[1] + 1) last[1] = Math.max(last[1], to)
    else ranges.push([from, to])
  }
  return ranges.map(([from, to]) => {
    const lines: DiffLine[] = []
    let oldNo = 0
    let newNo = 0
    // Line numbers at `from`: count lines of each side before it.
    for (let i = 0; i < from; i++) {
      if (ops[i]!.kind !== "add") oldNo++
      if (ops[i]!.kind !== "del") newNo++
    }
    const oldStart = oldNo + 1
    const newStart = newNo + 1
    for (let i = from; i <= to; i++) {
      const o = ops[i]!
      if (o.kind === "context") lines.push({ kind: "context", text: a[o.oldIndex]!, oldLine: ++oldNo, newLine: ++newNo })
      else if (o.kind === "del") lines.push({ kind: "del", text: a[o.oldIndex]!, oldLine: ++oldNo, newLine: null })
      else lines.push({ kind: "add", text: b[o.newIndex]!, oldLine: null, newLine: ++newNo })
    }
    const oldLines = lines.filter((l) => l.kind !== "add").length
    const newLines = lines.filter((l) => l.kind !== "del").length
    const hunk: Hunk = { id: "", oldStart: oldLines ? oldStart : oldStart - 1, oldLines, newStart: newLines ? newStart : newStart - 1, newLines, section: "", lines }
    hunk.id = hunkId(path, hunk)
    return hunk
  })
}

/** A FileDiff for two texts. */
export function diffTexts(path: string, before: string, after: string, context = 3): FileDiff {
  const a = splitLines(before)
  const b = splitLines(after)
  const hunks = toHunks(path, a, b, diffLines(a, b), context)
  const additions = hunks.reduce((s, h) => s + h.lines.filter((l) => l.kind === "add").length, 0)
  const deletions = hunks.reduce((s, h) => s + h.lines.filter((l) => l.kind === "del").length, 0)
  return { path, status: before === "" && after !== "" ? "added" : after === "" && before !== "" ? "deleted" : "modified", binary: false, hunks, additions, deletions }
}
