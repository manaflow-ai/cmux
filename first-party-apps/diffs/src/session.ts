// One diff pane's state: the input, the loaded diff, selection, review
// decisions and draft comments. Decisions go to the diff's owner through the
// proposed `diff.decide` (origin user: only called from tap handlers).

import type { DiffDecision, DiffInput } from "./interfaces/diff.ts"
import * as review from "./model/review.ts"
import type { FileDiff } from "./model/unified.ts"
import { load, SourceError, type Loaded } from "./source.ts"

export interface SessionError { code: string; message: string; op?: string }

export interface Session {
  input: () => DiffInput
  loaded: () => Loaded | null
  files: () => FileDiff[]
  loading: () => boolean
  error: () => SessionError | null
  actionError: () => SessionError | null
  selected: () => string | null
  select(path: string): void
  review: () => review.ReviewState
  collapsed: (path: string) => boolean
  toggleCollapsed(path: string): void
  shownLines: (path: string) => number | null
  showMore(path: string, by: number): void
  reload(): Promise<void>
  decideHunk(file: FileDiff, hunk: string, decision: review.Decision): Promise<void>
  decideFile(file: FileDiff, decision: review.Decision | null): Promise<void>
  decideAll(decision: review.Decision): Promise<void>
  comment(path: string, line: number, side: "old" | "new", body: string): Promise<void>
  removeComment(id: string): void
  submitted: () => string | null
  submitReview(): Promise<void>
}

const toError = (e: unknown): SessionError =>
  e instanceof SourceError ? { code: e.code, message: e.message, op: e.op } : { code: (e as { code?: string })?.code ?? "error", message: e instanceof Error ? e.message : String(e) }

let commentSeq = 0

export function createSession(input: () => DiffInput): Session {
  const [loaded, setLoaded] = signal<Loaded | null>(null)
  const [loading, setLoading] = signal(false)
  const [error, setError] = signal<SessionError | null>(null)
  const [actionError, setActionError] = signal<SessionError | null>(null)
  const [selected, setSelected] = signal<string | null>(null)
  const [state, setState] = signal<review.ReviewState>(review.emptyReview())
  const [collapsedSet, setCollapsed] = signal<Record<string, boolean>>({})
  const [shown, setShown] = signal<Record<string, number>>({})
  const [submitted, setSubmitted] = signal<string | null>(null)
  let generation = 0

  const files = () => loaded()?.files ?? []

  async function reload() {
    const gen = ++generation
    setLoading(true)
    try {
      const next = await load(input())
      if (gen !== generation) return
      setLoaded(next)
      setState(review.fromOwner(next.files, next.resource.decisions))
      setError(null)
      const sel = selected()
      if (!sel || !next.files.some((f) => f.path === sel)) setSelected(next.files[0]?.path ?? null)
    } catch (e) {
      if (gen === generation) setError(toError(e))
    } finally {
      if (gen === generation) setLoading(false)
    }
  }

  /** Sends unsent decisions to the owner; on failure the local state stays and the error shows. */
  async function send(next: review.ReviewState) {
    setState(next)
    const l = loaded()
    if (!l?.resource.diff) return // a documents diff has no owner to decide
    const decisions: DiffDecision[] = review.unsentDecisions(next, l.files)
    if (!decisions.length) return
    try {
      await cmux.call("diff.decide", { diff: l.resource.diff, decisions })
      setState((s) => review.confirm(s, l.files, decisions))
      setActionError(null)
    } catch (e) {
      setActionError({ ...toError(e), op: "diff.decide" })
    }
  }

  return {
    input,
    loaded,
    files,
    loading,
    error,
    actionError,
    selected,
    select: (path) => setSelected(path),
    review: state,
    collapsed: (path) => !!collapsedSet()[path],
    toggleCollapsed: (path) => setCollapsed((c) => ({ ...c, [path]: !c[path] })),
    shownLines: (path) => shown()[path] ?? null,
    showMore: (path, by) => setShown((s) => ({ ...s, [path]: (s[path] ?? 0) + by })),
    reload,
    decideHunk: (_file, hunk, decision) => send(review.decideHunk(state(), hunk, decision)),
    decideFile: (file, decision) => send(review.decideFile(state(), file, decision)),
    decideAll: async (decision) => {
      let next = state()
      for (const f of files()) next = review.decideFile(next, f, decision)
      await send(next)
    },
    async comment(path, line, side, body) {
      const next = review.addComment(state(), { path, line, side, body }, `c${++commentSeq}`)
      setState(next)
      const l = loaded()
      if (!l?.resource.diff || l.feedItem) return // feed reviews carry comments as answer notes
      try {
        await cmux.call("diff.comment.add", { diff: l.resource.diff, path, line, side, body })
      } catch (e) {
        setActionError({ ...toError(e), op: "diff.comment.add" })
      }
    },
    removeComment: (id) => setState(review.removeComment(state(), id)),
    submitted,
    async submitReview() {
      const l = loaded()
      if (!l?.feedItem) return
      const s = state()
      const verdict = review.verdict(s, l.files)
      // Feed `review` answer schema: {verdict, comment?, notes?: [{path, line?, text}]}.
      const value = { verdict, notes: s.comments.map((c) => ({ path: c.path, line: c.line, text: c.body })) }
      try {
        await cmux.call("feed.answer", { item: l.feedItem.id, value })
        setSubmitted(verdict)
        setActionError(null)
      } catch (e) {
        setActionError({ ...toError(e), op: "feed.answer" })
      }
    }
  }
}
