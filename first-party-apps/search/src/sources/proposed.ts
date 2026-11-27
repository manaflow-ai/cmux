// Shapes of the operations this app proposes (README "Proposed operations").
// None exists yet: the host answers `operation.unsupported` and the app says
// what is missing. Offsets are UTF-16 code units into the returned line text.

/** `terminal.search` (read, `terminal:read`, owner: session host). */
export interface TerminalSearchParams {
  query: string
  regex?: boolean
  case_sensitive?: boolean
  /** Only these terminals; default every terminal of the session. */
  terminals?: string[]
  /** Also search transcripts of terminals closed in this session's retention window. */
  include_closed?: boolean
  /** Total matches (default 50, max 500). */
  limit?: number
  /** Matches per terminal (default 3). */
  per_terminal?: number
  /** Characters of context on each side in `line_text` (default 80). */
  context_chars?: number
  /** A newer call with the same id from the same app supersedes this one (`request.superseded`). */
  search_id?: string
}
export interface TerminalSearchMatch {
  terminal: string
  tab: string | null
  title: string
  closed: boolean
  /** Opaque absolute row id, valid for `terminal.viewport.reveal`. */
  row: string
  line_text: string
  match_start: number
  match_length: number
  last_output_at_ms: number | null
}
export interface TerminalSearchResult {
  matches: TerminalSearchMatch[]
  truncated: boolean
}

/** `browser.history.search` (read, `browser_history:read`, owner: browser history store). */
export interface HistorySearchParams {
  query: string
  regex?: boolean
  limit?: number
  search_id?: string
}
export interface HistoryEntry {
  url: string
  title: string
  last_visit_ms: number
  visit_count: number
}
export interface HistorySearchResult {
  entries: HistoryEntry[]
  truncated: boolean
}

/** `fs.search` (read, `fs:read` limited to granted roots, owner: session host on the machine with the files). */
export interface FsSearchParams {
  roots: string[]
  query: string
  mode?: "name" | "content" | "both"
  regex?: boolean
  case_sensitive?: boolean
  include?: string[]
  exclude?: string[]
  limit?: number
  search_id?: string
}
export interface FsMatch {
  root: string
  path: string
  relative: string
  kind: "name" | "content"
  line?: number
  column?: number
  line_text?: string
  match_start: number
  match_length: number
  modified_ms: number | null
}
export interface FsSearchResult {
  matches: FsMatch[]
  truncated: boolean
  /** Roots the grant does not cover; the host never searched them. */
  denied_roots?: string[]
}

/** `search.providers.query` (read, `search:read`, owner: app supervisor; fans out to `searchProviders` contributions). */
export interface ProvidersQueryParams {
  query: string
  providers?: string[]
  limit_per_provider?: number
  search_id?: string
}
export interface ProviderItem {
  id: string
  title: string
  subtitle?: string
  line_text?: string
  match_start?: number
  match_length?: number
  symbol?: string
  updated_at_ms?: number
  /** A command of the providing app; the caller runs it with `action.run` (`app.<app id>#<command>`). */
  open: { command: string; args?: Record<string, unknown> }
}
export interface ProviderResult {
  /** Global contribution id `<app id>#<provider id>`. */
  provider: string
  title: string
  items: ProviderItem[]
  truncated: boolean
  error?: { code: string; message: string } | null
}
export interface ProvidersQueryResult {
  providers: ProviderResult[]
}
