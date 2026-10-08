/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// State of one mounted search surface: the query, filter chip, scope and regex
// toggles, the latest response and the selection. Typing debounces with a
// one-shot timer; every run gets a generation so a slow, older answer never
// replaces a newer one, and owners get a stable search_id so they drop
// superseded work.

import { emptyResponse, runSearch, type SearchResponse } from "../engine.ts"
import { rememberOpened, rememberSearch, opened, loadMemory } from "../memory.ts"
import { activeHit, type Hit } from "../model.ts"
import { openHit } from "../open.ts"
import { effectiveSources, parseQuery, SOURCES, isSourceId, type Scope, type SourceId } from "../query.ts"
import { settings } from "../settings.ts"

export type Density = "compact" | "full"

const DEBOUNCE_MS = 150
/** Events after which names may have changed; a visible, non-empty search re-runs once. */
const INVALIDATING = ["workspace.changed", "tab.changed", "terminal.changed", "browser.changed"]

export interface Controller {
  query: () => string
  filter: () => SourceId | null
  scope: () => Scope
  /** The scope one search uses: `in:here` / `in:all` in the query win over the toggle. */
  effectiveScope: () => Scope
  regex: () => boolean
  response: () => SearchResponse
  loading: () => boolean
  selectedId: () => string | null
  /** The hit Return opens. */
  active: () => Hit | null
  edit(text: string): void
  submit(text: string): void
  cancel(): void
  setFilter(source: SourceId | null): void
  toggleScope(): void
  toggleRegex(): void
  select(hit: Hit): void
  open(hit: Hit): void
  useRecent(query: string): void
}

let surfaces = 0

export function createController(density: Density, ctx: { contribution?: string } = {}): Controller {
  const surfaceId = `${ctx.contribution ?? "search"}:${++surfaces}`
  const [query, setQuery] = signal("")
  const [filter, setFilterSig] = signal<SourceId | null>(null)
  const [scopeOverride, setScopeOverride] = signal<Scope | null>(null)
  const [regex, setRegex] = signal(false)
  const [response, setResponse] = signal<SearchResponse>(emptyResponse("", "all"))
  const [loading, setLoading] = signal(false)
  const [selectedId, setSelectedId] = signal<string | null>(null)
  const scope = () => scopeOverride() ?? settings().defaultScope
  let generation = 0
  let timer: number | null = null
  let lastRun = ""

  void loadMemory()

  const key = () => `${query()}\u0000${filter()}\u0000${scope()}\u0000${regex()}`

  const run = async () => {
    if (timer !== null) cmux.timer.clear(timer)
    timer = null
    const gen = ++generation
    lastRun = key()
    const parsed = parseQuery(query(), { regex: regex() })
    const effectiveScope = parsed.scope ?? scope()
    if (!parsed.text) {
      setResponse(emptyResponse(parsed.raw, effectiveScope))
      setLoading(false)
      return
    }
    setLoading(true)
    const accept = (r: SearchResponse) => {
      if (gen !== generation) return
      setResponse(r)
      const sel = selectedId()
      if (sel && !r.ranked.some((h) => h.id === sel)) setSelectedId(null)
    }
    try {
      const final = await runSearch(
        {
          query: parsed,
          sources: effectiveSources(parsed, filter(), settings().sources),
          scope: effectiveScope,
          density,
          limit: 50,
          searchId: surfaceId,
          opened: opened(),
          selfId: cmux.app.id,
          nowMs: Date.now()
        },
        (op, params) => cmux.call(op, params),
        accept
      )
      accept(final)
    } finally {
      if (gen === generation) setLoading(false)
    }
  }

  const schedule = (ms = DEBOUNCE_MS) => {
    if (timer !== null) cmux.timer.clear(timer)
    timer = cmux.timer.after(ms, () => void run())
  }

  for (const stream of INVALIDATING) cmux.events.on(stream, () => (query().trim() && !loading() ? schedule(300) : undefined))

  const open = (hit: Hit) => {
    rememberSearch(query(), settings().rememberRecent)
    rememberOpened(hit.id, Date.now())
    void openHit(hit).catch((e) => cmux.log("open failed", String(e)))
  }

  return {
    query,
    filter,
    scope,
    effectiveScope: () => parseQuery(query()).scope ?? scope(),
    regex,
    response,
    loading,
    selectedId,
    active: () => activeHit(response().ranked, selectedId()),
    edit(text) {
      setQuery(text)
      setSelectedId(null)
      schedule()
    },
    submit(text) {
      setQuery(text)
      // Return on stale results searches first; Return on current results opens the active hit.
      if (key() !== lastRun || loading()) return void run()
      const hit = activeHit(response().ranked, selectedId())
      if (hit) open(hit)
    },
    cancel() {
      setQuery("")
      setSelectedId(null)
      void run()
    },
    setFilter(source) {
      setFilterSig(source && isSourceId(source) ? source : null)
      void run()
    },
    toggleScope() {
      setScopeOverride(scope() === "all" ? "workspace" : "all")
      void run()
    },
    toggleRegex() {
      setRegex(!regex())
      void run()
    },
    select(hit) {
      setSelectedId(hit.id)
    },
    open,
    useRecent(q) {
      setQuery(q)
      void run()
    }
  }
}

export { SOURCES }
