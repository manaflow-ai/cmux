// Unified diff (git format) parser. Pure; no cmux API.

import type { FileStatus } from "../interfaces/diff.ts"

export type LineKind = "context" | "add" | "del"

export interface DiffLine {
  kind: LineKind
  text: string
  oldLine: number | null
  newLine: number | null
  /** "\ No newline at end of file" followed this line. */
  noNewline?: boolean
}

export interface Hunk {
  id: string
  oldStart: number
  oldLines: number
  newStart: number
  newLines: number
  /** Text after the second @@ (often the enclosing function). */
  section: string
  lines: DiffLine[]
}

export interface FileDiff {
  path: string
  oldPath?: string
  status: FileStatus
  binary: boolean
  hunks: Hunk[]
  additions: number
  deletions: number
}

const HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$/

/** FNV-1a, 32 bit, as 8 hex digits. Stable hunk ids across reloads of the same content. */
export function fnv1a(text: string): string {
  let h = 0x811c9dc5
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h.toString(16).padStart(8, "0")
}

export const hunkId = (path: string, h: Pick<Hunk, "oldStart" | "newStart" | "lines">) =>
  `${path}@${h.oldStart},${h.newStart}#${fnv1a(h.lines.map((l) => (l.kind === "add" ? "+" : l.kind === "del" ? "-" : " ") + l.text).join("\n"))}`

/** Removes git's `a/` / `b/` prefix and C-style quoting. */
export function cleanPath(raw: string): string | null {
  let p = raw.trim()
  if (p === "/dev/null") return null
  if (p.startsWith('"') && p.endsWith('"')) {
    p = p.slice(1, -1).replace(/\\(["\\])/g, "$1").replace(/\\t/g, "\t").replace(/\\n/g, "\n")
  }
  const tab = p.indexOf("\t")
  if (tab >= 0) p = p.slice(0, tab)
  return p.replace(/^[ab]\//, "")
}

/** Paths from `diff --git a/x b/y` when both are unquoted and equal length halves are ambiguous. */
function pathsFromGitHeader(rest: string): [string, string] | null {
  const quoted = rest.match(/^"((?:[^"\\]|\\.)*)" "((?:[^"\\]|\\.)*)"$/)
  if (quoted) return [cleanPath(`"${quoted[1]}"`) ?? "", cleanPath(`"${quoted[2]}"`) ?? ""]
  const m = rest.match(/^a\/(.*) b\/(.*)$/)
  return m ? [m[1]!, m[2]!] : null
}

function newFile(path: string): FileDiff {
  return { path, status: "modified", binary: false, hunks: [], additions: 0, deletions: 0 }
}

/** Parses a multi-file unified diff. Unknown lines are ignored; malformed hunks end at the next header. */
export function parseUnifiedDiff(text: string): FileDiff[] {
  const files: FileDiff[] = []
  const lines = text.replace(/\r\n/g, "\n").split("\n")
  let file: FileDiff | null = null
  let hunk: Hunk | null = null
  let oldNo = 0
  let newNo = 0
  let oldLeft = 0
  let newLeft = 0

  const finishHunk = () => {
    if (file && hunk) {
      hunk.id = hunkId(file.path, hunk)
      file.hunks.push(hunk)
    }
    hunk = null
  }
  const finishFile = () => {
    finishHunk()
    if (file) files.push(file)
    file = null
  }

  for (const line of lines) {
    if (hunk && (oldLeft > 0 || newLeft > 0)) {
      const c = line[0]
      if (c === " " || (c === undefined && line === "")) {
        hunk.lines.push({ kind: "context", text: line.slice(1), oldLine: oldNo++, newLine: newNo++ })
        oldLeft--
        newLeft--
        continue
      }
      if (c === "-") {
        hunk.lines.push({ kind: "del", text: line.slice(1), oldLine: oldNo++, newLine: null })
        file!.deletions++
        oldLeft--
        continue
      }
      if (c === "+") {
        hunk.lines.push({ kind: "add", text: line.slice(1), oldLine: null, newLine: newNo++ })
        file!.additions++
        newLeft--
        continue
      }
    }
    if (line.startsWith("\\ ")) {
      const last = (hunk as Hunk | null)?.lines.at(-1)
      if (last) last.noNewline = true
      continue
    }
    if (line.startsWith("diff --git ")) {
      finishFile()
      const paths = pathsFromGitHeader(line.slice("diff --git ".length))
      file = newFile(paths?.[1] ?? "")
      if (paths && paths[0] !== paths[1]) file.oldPath = paths[0]
      continue
    }
    const h = line.match(HUNK_HEADER)
    if (h) {
      if (!file) file = newFile("")
      finishHunk()
      hunk = {
        id: "",
        oldStart: Number(h[1]),
        oldLines: h[2] === undefined ? 1 : Number(h[2]),
        newStart: Number(h[3]),
        newLines: h[4] === undefined ? 1 : Number(h[4]),
        section: h[5] ?? "",
        lines: []
      }
      oldNo = hunk.oldStart
      newNo = hunk.newStart
      oldLeft = hunk.oldLines
      newLeft = hunk.newLines
      continue
    }
    if (line.startsWith("--- ")) {
      // A plain `diff -u` without `diff --git` starts a file here.
      if (!file || (file.hunks.length > 0 || hunk)) {
        finishFile()
        file = newFile("")
      }
      const old = cleanPath(line.slice(4))
      if (old === null) file.status = "added"
      else if (!file.path) file.path = old
      if (old && old !== file.path) file.oldPath = old
      continue
    }
    if (line.startsWith("+++ ") && file) {
      const next = cleanPath(line.slice(4))
      if (next === null) file.status = "deleted"
      else {
        if (file.oldPath === undefined && file.path && file.path !== next) file.oldPath = file.path
        file.path = next
        if (file.oldPath === next) delete file.oldPath
      }
      continue
    }
    if (!file) continue
    if (line.startsWith("new file mode")) file.status = "added"
    else if (line.startsWith("deleted file mode")) file.status = "deleted"
    else if (line.startsWith("rename from ")) {
      file.oldPath = line.slice("rename from ".length)
      file.status = "renamed"
    } else if (line.startsWith("rename to ")) {
      file.path = line.slice("rename to ".length)
      file.status = "renamed"
    } else if (line.startsWith("copy from ")) {
      file.oldPath = line.slice("copy from ".length)
      file.status = "copied"
    } else if (line.startsWith("Binary files ") || line === "GIT binary patch") {
      file.binary = true
      if (file.status === "modified") file.status = "binary"
    }
  }
  finishFile()
  return files.filter((f) => f.path || f.oldPath).map((f) => (f.path ? f : { ...f, path: f.oldPath! }))
}
