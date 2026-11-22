// Query syntax. Plain text matches everywhere. Leading prefixes narrow the
// sources (`t:` terminals, `f:` files, `b:` browser, `w:` workspaces,
// `a:` app items; several may be combined). `in:here` / `in:all` override the
// scope. `/pattern/` is a regular expression; `"exact phrase"` turns off fuzzy
// name matching. Case is smart: an uppercase letter makes the match
// case-sensitive.

export type SourceId = "workspaces" | "terminals" | "browser" | "apps" | "files"
export type Scope = "workspace" | "all"

/** Display and search order of the result groups. */
export const SOURCES: readonly SourceId[] = ["workspaces", "terminals", "browser", "apps", "files"]

export const PREFIXES: Readonly<Record<string, SourceId>> = { w: "workspaces", t: "terminals", b: "browser", a: "apps", f: "files" }

export interface ParsedQuery {
  raw: string
  /** The text to match, without prefixes, scope tokens, slashes or quotes. */
  text: string
  /** Sources named by prefixes, or null when the query names none. */
  sources: SourceId[] | null
  regex: boolean
  exact: boolean
  caseSensitive: boolean
  scope: Scope | null
  /** Set when `regex` is true and the pattern does not compile. */
  error: string | null
}

const PREFIX = /^([wtbaf]):\s*/i
const SCOPE_TOKEN = /(^|\s)in:(here|all)(?=\s|$)/i
const REGEX_LITERAL = /^\/(.+)\/([a-z]*)$/

export function parseQuery(raw: string, options: { regex?: boolean } = {}): ParsedQuery {
  let rest = raw.trim()
  let scope: Scope | null = null
  const scopeMatch = SCOPE_TOKEN.exec(rest)
  if (scopeMatch) {
    scope = scopeMatch[2]!.toLowerCase() === "here" ? "workspace" : "all"
    rest = (rest.slice(0, scopeMatch.index) + rest.slice(scopeMatch.index + scopeMatch[0].length)).trim()
  }
  const sources: SourceId[] = []
  for (let m = PREFIX.exec(rest); m; m = PREFIX.exec(rest)) {
    const source = PREFIXES[m[1]!.toLowerCase()]!
    if (!sources.includes(source)) sources.push(source)
    rest = rest.slice(m[0].length)
  }
  let regex = options.regex === true
  let exact = false
  let flagsCaseInsensitive = false
  const literal = REGEX_LITERAL.exec(rest)
  if (literal) {
    regex = true
    rest = literal[1]!
    flagsCaseInsensitive = literal[2]!.includes("i")
  } else if (!regex && rest.length >= 2 && rest.startsWith('"') && rest.endsWith('"')) {
    exact = true
    rest = rest.slice(1, -1)
  }
  const caseSensitive = !flagsCaseInsensitive && /[A-Z]/.test(regex ? rest.replace(/\\[A-Za-z]/g, "") : rest)
  let error: string | null = null
  if (regex && rest) {
    try {
      new RegExp(rest, caseSensitive ? "" : "i")
    } catch (e) {
      error = e instanceof Error ? e.message : String(e)
    }
  }
  return { raw, text: rest, sources: sources.length ? sources : null, regex, exact, caseSensitive, scope, error }
}

/** The sources one search covers: prefixes win over the filter chip, which wins over the enabled list. */
export function effectiveSources(query: ParsedQuery, filter: SourceId | null, enabled: readonly SourceId[]): SourceId[] {
  const wanted = query.sources ?? (filter ? [filter] : SOURCES)
  return SOURCES.filter((s) => wanted.includes(s) && enabled.includes(s))
}

export const isSourceId = (v: unknown): v is SourceId => typeof v === "string" && (SOURCES as readonly string[]).includes(v)
