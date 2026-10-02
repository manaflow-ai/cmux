// Directory entries as the `cmux.fs.provider/1` owner returns them, and the
// one comparator both the owner and the app use (finder.md section 4.2: the
// owner sorts; the app re-sorts only a COMPLETE listing and places watch events).

import { extension } from "./handles.ts"

export type EntryKind = "file" | "dir" | "symlink" | "other"

export type Entry = {
  name: string
  kind: EntryKind
  /** Bytes; null for directories and when the owner does not know. */
  size: number | null
  /** Milliseconds since the epoch; null when unknown. */
  mtime: number | null
  /** Owner's type id (for example "public.png", "net.daringfireball.markdown"); optional. */
  type?: string
  hidden?: boolean
  /** For a symlink: the kind of its target, when the owner resolved it inside the root. */
  target_kind?: EntryKind | null
}

export type SortKey = "name" | "modified" | "size" | "kind"
export type Sort = { key: SortKey; dir: "asc" | "desc"; dirsFirst: boolean }
export const DEFAULT_SORT: Sort = { key: "name", dir: "asc", dirsFirst: true }

export type Filter = { query: string; hidden: boolean }
export const DEFAULT_FILTER: Filter = { query: "", hidden: false }

/** Natural, case-insensitive order ("file2" < "file10"); no Intl so every engine agrees with the owner. */
export function naturalCompare(a: string, b: string): number {
  const ax = a.toLowerCase().match(/\d+|\D+/g) ?? []
  const bx = b.toLowerCase().match(/\d+|\D+/g) ?? []
  for (let i = 0; i < Math.min(ax.length, bx.length); i++) {
    const x = ax[i]!
    const y = bx[i]!
    if (x === y) continue
    const xn = /^\d/.test(x)
    const yn = /^\d/.test(y)
    if (xn && yn) {
      const d = Number(x) - Number(y)
      if (d !== 0) return d < 0 ? -1 : 1
      if (x.length !== y.length) return x.length < y.length ? -1 : 1
      continue
    }
    return x < y ? -1 : 1
  }
  if (ax.length !== bx.length) return ax.length < bx.length ? -1 : 1
  return a < b ? -1 : a > b ? 1 : 0
}

const isDir = (e: Entry) => e.kind === "dir" || (e.kind === "symlink" && e.target_kind === "dir")

export type KindGroup = "folder" | "text" | "markdown" | "code" | "image" | "pdf" | "archive" | "media" | "other"

const BY_EXT: Record<string, KindGroup> = {
  md: "markdown", markdown: "markdown",
  txt: "text", log: "text", csv: "text", json: "code", yaml: "code", yml: "code", toml: "code",
  ts: "code", tsx: "code", js: "code", swift: "code", rs: "code", go: "code", py: "code", sh: "code", c: "code", h: "code", zig: "code",
  png: "image", jpg: "image", jpeg: "image", gif: "image", webp: "image", heic: "image", svg: "image",
  pdf: "pdf",
  zip: "archive", gz: "archive", tgz: "archive", tar: "archive", xz: "archive", zst: "archive",
  mp4: "media", mov: "media", mp3: "media", wav: "media"
}

export function kindGroup(e: Entry): KindGroup {
  if (isDir(e)) return "folder"
  return BY_EXT[extension(e.name)] ?? "other"
}

export function compareEntries(sort: Sort) {
  const sign = sort.dir === "asc" ? 1 : -1
  return (a: Entry, b: Entry): number => {
    if (sort.dirsFirst) {
      const d = Number(isDir(b)) - Number(isDir(a))
      if (d !== 0) return d
    }
    let c = 0
    switch (sort.key) {
      case "modified":
        c = (a.mtime ?? 0) - (b.mtime ?? 0)
        break
      case "size":
        c = (a.size ?? -1) - (b.size ?? -1)
        break
      case "kind":
        c = naturalCompare(kindGroup(a), kindGroup(b)) || naturalCompare(extension(a.name), extension(b.name))
        break
      default:
        c = 0
    }
    if (c !== 0) return c < 0 ? -sign : sign
    // Name is always the tiebreaker, so the order is total and equals the owner's.
    return sign * naturalCompare(a.name, b.name)
  }
}

export function matchesFilter(e: Entry, f: Filter): boolean {
  if (!f.hidden && (e.hidden || e.name.startsWith("."))) return false
  if (f.query && !e.name.toLowerCase().includes(f.query.toLowerCase())) return false
  return true
}

/** Index where `e` goes in an array sorted by `cmp` (binary search). */
export function insertionIndex(sorted: readonly Entry[], e: Entry, cmp: (a: Entry, b: Entry) => number): number {
  let lo = 0
  let hi = sorted.length
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    if (cmp(sorted[mid]!, e) <= 0) lo = mid + 1
    else hi = mid
  }
  return lo
}
