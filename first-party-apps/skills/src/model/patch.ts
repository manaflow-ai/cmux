// Parses the unified patch an owner returns with a planned change, for the
// inline preview. Tolerant: unknown lines are skipped, "\ No newline" ignored.

export type PatchLine = { kind: "context" | "add" | "del"; text: string; oldLine: number | null; newLine: number | null }
export type PatchHunk = { header: string; lines: PatchLine[] }
export type PatchFile = { path: string; oldPath: string | null; hunks: PatchHunk[]; additions: number; deletions: number }

const strip = (p: string) => p.replace(/^[ab]\//, "")

export function parsePatch(text: string): PatchFile[] {
  const files: PatchFile[] = []
  let file: PatchFile | null = null
  let hunk: PatchHunk | null = null
  let oldNo = 0, newNo = 0
  for (const line of text.split("\n")) {
    if (line.startsWith("--- ")) {
      const old = line.slice(4).trim()
      file = { path: "", oldPath: old === "/dev/null" ? null : strip(old), hunks: [], additions: 0, deletions: 0 }
      files.push(file)
      hunk = null
    } else if (line.startsWith("+++ ") && file) {
      const p = line.slice(4).trim()
      file.path = p === "/dev/null" ? (file.oldPath ?? "") : strip(p)
    } else if (line.startsWith("@@") && file) {
      const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line)
      oldNo = m ? Number(m[1]) : 0
      newNo = m ? Number(m[2]) : 0
      hunk = { header: line, lines: [] }
      file.hunks.push(hunk)
    } else if (hunk && file && line.length > 0 && "+- ".includes(line[0]!)) {
      const kind = line[0] === "+" ? "add" : line[0] === "-" ? "del" : "context"
      const text = line.slice(1)
      if (kind === "add") {
        hunk.lines.push({ kind, text, oldLine: null, newLine: newNo++ })
        file.additions++
      } else if (kind === "del") {
        hunk.lines.push({ kind, text, oldLine: oldNo++, newLine: null })
        file.deletions++
      } else hunk.lines.push({ kind, text, oldLine: oldNo++, newLine: newNo++ })
    }
  }
  return files.filter((f) => f.path || f.oldPath)
}
