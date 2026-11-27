// Parses what the user types into "Install from…": a git URL (https or ssh,
// optional #ref and //subfolder), the owner/repo shorthand for GitHub, or a
// store id (store:<publisher>/<name>). Anything else is rejected before any
// op is called. Only https and ssh git transports are accepted.

export type InstallSource = { git: string; ref: string | null; path: string | null } | { store: string }

export type ParseResult = { ok: true; source: InstallSource; label: string } | { ok: false; reason: "empty" | "scheme" | "shape" }

const SEGMENT = /^[A-Za-z0-9._-]+$/

export function parseSource(raw: string): ParseResult {
  const text = raw.trim()
  if (!text) return { ok: false, reason: "empty" }
  if (text.startsWith("store:")) {
    const id = text.slice(6)
    return /^[a-z0-9-]+\/[a-z0-9][a-z0-9-]*$/.test(id) ? { ok: true, source: { store: id }, label: id } : { ok: false, reason: "shape" }
  }
  let rest = text
  let ref: string | null = null
  const hash = rest.indexOf("#")
  if (hash >= 0) {
    ref = rest.slice(hash + 1) || null
    rest = rest.slice(0, hash)
  }
  let path: string | null = null
  const sub = rest.indexOf("//", rest.indexOf("://") >= 0 ? rest.indexOf("://") + 3 : 0)
  if (sub >= 0) {
    path = rest.slice(sub + 2).replace(/\/+$/, "") || null
    rest = rest.slice(0, sub)
  }
  if (path && path.split("/").some((p) => p === ".." || !SEGMENT.test(p))) return { ok: false, reason: "shape" }
  if (ref && !/^[A-Za-z0-9._\/-]+$/.test(ref)) return { ok: false, reason: "shape" }
  let git: string
  if (/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(rest)) git = `https://github.com/${rest.replace(/\.git$/, "")}.git`
  else if (/^https:\/\/[^\s/]+\/\S+$/.test(rest)) git = rest
  else if (/^git@[^\s:]+:\S+$/.test(rest) || /^ssh:\/\/\S+$/.test(rest)) git = rest
  else if (/^[a-z][a-z0-9+.-]*:/.test(rest)) return { ok: false, reason: "scheme" }
  else return { ok: false, reason: "shape" }
  const name = git.replace(/\.git$/, "").split(/[/:]/).filter(Boolean).slice(-2).join("/")
  return { ok: true, source: { git, ref, path }, label: [name, path].filter(Boolean).join("/") + (ref ? `@${ref}` : "") }
}

/** "name command args…" or "name https://url" for Add MCP Server; null when it does not parse. */
export function parseServerLine(raw: string): { name: string; transport: "stdio"; command: string; args: string[] } | { name: string; transport: "http"; url: string } | null {
  const parts = raw.trim().split(/\s+/).filter(Boolean)
  if (parts.length < 2 || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/.test(parts[0]!)) return null
  const [name, first, ...rest] = parts as [string, string, ...string[]]
  if (/^https:\/\//.test(first)) return rest.length ? null : { name, transport: "http", url: first }
  if (/^[a-z]+:\/\//.test(first)) return null
  return { name, transport: "stdio", command: first, args: rest }
}
