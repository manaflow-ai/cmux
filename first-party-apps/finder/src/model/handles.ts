// Handles and root-relative paths (plans/cmux-next/finder.md section 2).
//
// The app never names an absolute path, a host name or a credential. It holds
// opaque handles the shell gave it (`root_…` from the file panel or a
// connection, `conn_…` from the connect sheet) and paths RELATIVE to a root.
// These helpers keep that model honest: a relative path can never climb out of
// its root, and a display path is only ever the owner's display string.

export type HandleKind = "root" | "conn" | "cred" | "doc" | "lst" | "job" | "undo" | "img" | "wat"

const HANDLE = /^[a-z]{3,4}_[A-Za-z0-9_-]{3,64}$/

export function isHandle(kind: HandleKind, value: unknown): value is string {
  return typeof value === "string" && value.startsWith(`${kind}_`) && HANDLE.test(value)
}

/** A place in a file system: which connection, which root on it, which path under the root ("" is the root). */
export type Location = { conn: string; root: string; path: string }

export class PathError extends Error {
  constructor(
    readonly code: "path.escapes_root" | "path.invalid_name",
    message: string
  ) {
    super(message)
  }
}

/** A single path component the owner will accept as a new name. */
export function validName(name: string): boolean {
  return name.length > 0 && name.length <= 255 && name !== "." && name !== ".." && !/[/\u0000]/.test(name)
}

/** Normalizes a root-relative path: no leading or trailing slash, no empty or "." segments; ".." is refused, never resolved. */
export function normalizeRel(path: string): string {
  const out: string[] = []
  for (const seg of path.split("/")) {
    if (seg === "" || seg === ".") continue
    if (seg === "..") throw new PathError("path.escapes_root", "a relative path may not contain ..")
    if (seg.includes("\u0000")) throw new PathError("path.invalid_name", "a path may not contain NUL")
    out.push(seg)
  }
  return out.join("/")
}

export function join(path: string, name: string): string {
  if (!validName(name)) throw new PathError("path.invalid_name", `invalid name: ${JSON.stringify(name)}`)
  const base = normalizeRel(path)
  return base === "" ? name : `${base}/${name}`
}

/** The parent path, or null at the root (the root is the ceiling: there is no "up" past it). */
export function parent(path: string): string | null {
  const p = normalizeRel(path)
  if (p === "") return null
  const i = p.lastIndexOf("/")
  return i < 0 ? "" : p.slice(0, i)
}

export function basename(path: string): string {
  const p = normalizeRel(path)
  const i = p.lastIndexOf("/")
  return i < 0 ? p : p.slice(i + 1)
}

export function extension(name: string): string {
  const i = name.lastIndexOf(".")
  return i <= 0 ? "" : name.slice(i + 1).toLowerCase()
}

export type Crumb = { label: string; path: string }

/** Path bar segments: the root's label first, then each directory under it. */
export function crumbs(rootLabel: string, path: string): Crumb[] {
  const out: Crumb[] = [{ label: rootLabel, path: "" }]
  let acc = ""
  for (const seg of normalizeRel(path).split("/").filter(Boolean)) {
    acc = acc === "" ? seg : `${acc}/${seg}`
    out.push({ label: seg, path: acc })
  }
  return out
}

/** Collapses the middle of a long path bar so it fits: root, an ellipsis, then the last `keep` segments. */
export function collapseCrumbs(list: Crumb[], keep = 3): Array<Crumb | null> {
  if (list.length <= keep + 1) return list
  return [list[0]!, null, ...list.slice(list.length - keep)]
}

/** What the user sees: the owner's display path for the root (for example "~/src" or "build-box:/srv") plus the relative path. */
export function displayPath(rootDisplay: string, path: string): string {
  const rel = normalizeRel(path)
  if (rel === "") return rootDisplay
  return rootDisplay.endsWith("/") ? `${rootDisplay}${rel}` : `${rootDisplay}/${rel}`
}

export const sameLocation = (a: Location | null, b: Location | null) =>
  !!a && !!b && a.conn === b.conn && a.root === b.root && normalizeRel(a.path) === normalizeRel(b.path)

export const locationKey = (l: Location) => `${l.conn}|${l.root}|${normalizeRel(l.path)}`

/** POSIX shell quoting for a path the host resolved for a terminal on the same machine. */
export function shellQuote(path: string): string {
  if (path !== "" && /^[A-Za-z0-9_/.,:@%+=~-]+$/.test(path) && !path.startsWith("~")) return path
  return `'${path.replace(/'/g, `'\\''`)}'`
}
