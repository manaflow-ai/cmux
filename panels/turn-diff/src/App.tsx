import React, { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { parseUnifiedDiff, type DiffFile } from "./diffModel"
import { RepoGroup } from "./RepoGroup"

type Status = "Idle" | "Running" | "Unknown"
type RootState =
  | { kind: "unknown" }
  | { kind: "ok"; root: string }
  | { kind: "missing"; cwd: string }

interface RepoPayload {
  root: string
  diff: string
  isActive: boolean
}

interface RepoEntry {
  root: string
  isActive: boolean
  files: DiffFile[]
  /** Per-file expansion state, scoped to this repo so two repos can have
   *  files with the same relative path without colliding. */
  expandedFiles: Set<string>
}

/** Below this panel width we render the unified (single-column) diff view.
 *  At or above it we render the original side-by-side renderer. */
export const UNIFIED_VIEW_WIDTH_THRESHOLD = 600

export function App() {
  const [repos, setRepos] = useState<RepoEntry[]>([])
  const [status, setStatus] = useState<Status>("Unknown")
  const [rootState, setRootState] = useState<RootState>({ kind: "unknown" })
  const [expandedRepos, setExpandedRepos] = useState<Set<string>>(() => new Set())
  const [panelWidth, setPanelWidth] = useState<number>(() =>
    typeof window !== "undefined" ? window.innerWidth : UNIFIED_VIEW_WIDTH_THRESHOLD
  )
  const panelRef = useRef<HTMLDivElement | null>(null)
  /** Tracks which repos we've already seen so newly-discovered repos can pick
   *  up the right default expansion state (only the active one is expanded). */
  const seenReposRef = useRef<Set<string>>(new Set())

  // Apply a multi-repo diff payload from Swift. We MERGE rather than replace
  // the existing per-file expansion state so the user's manual file toggles
  // survive across turns.
  const applyMultiDiff = useCallback((payload: RepoPayload[]) => {
    setRepos((prev) => {
      const prevByRoot = new Map(prev.map((r) => [r.root, r]))
      const next: RepoEntry[] = payload.map((p) => {
        const files = parseDiffSafe(p.diff)
        const prevEntry = prevByRoot.get(p.root)
        // Drop expansion state for files that no longer appear in this repo's
        // diff (they were undone, etc.) — same trick the per-file panel used.
        const live = new Set(files.map((f) => f.path))
        const carried = new Set<string>()
        if (prevEntry) {
          for (const path of prevEntry.expandedFiles) {
            if (live.has(path)) carried.add(path)
          }
        }
        return {
          root: p.root,
          isActive: p.isActive,
          files,
          expandedFiles: carried,
        }
      })
      return next
    })

    // Adjust expandedRepos: keep current toggles for repos we've already seen,
    // and default-expand any newly-discovered repo iff it's the active one.
    setExpandedRepos((prev) => {
      const seen = seenReposRef.current
      const next = new Set<string>()
      for (const p of payload) {
        if (seen.has(p.root)) {
          if (prev.has(p.root)) next.add(p.root)
        } else {
          if (p.isActive) next.add(p.root)
          seen.add(p.root)
        }
      }
      // Optimization: avoid identity churn when nothing changed.
      if (setEquals(prev, next)) return prev
      return next
    })
  }, [])

  useEffect(() => {
    const onDiff = (e: Event) => {
      const detail = (e as CustomEvent).detail
      if (detail && Array.isArray(detail.repos)) {
        const repos = (detail.repos as unknown[]).filter(isRepoPayload)
        applyMultiDiff(repos)
        return
      }
      // Back-compat: if Swift ever sends the old string-only payload, treat it
      // as a single anonymous repo so the panel still renders something.
      if (typeof detail === "string") {
        applyMultiDiff([{ root: "(unknown)", diff: detail, isActive: true }])
        return
      }
      if (detail && typeof detail.unifiedDiff === "string") {
        applyMultiDiff([
          { root: "(unknown)", diff: detail.unifiedDiff as string, isActive: true },
        ])
      }
    }
    const onStatus = (e: Event) => {
      const detail = (e as CustomEvent).detail
      if (typeof detail === "string") setStatus(detail as Status)
    }
    const onRoot = (e: Event) => {
      const detail = (e as CustomEvent).detail
      if (detail && typeof detail.root === "string") {
        setRootState({ kind: "ok", root: detail.root })
      }
    }
    const onNoRoot = (e: Event) => {
      const detail = (e as CustomEvent).detail
      const cwd = (detail && typeof detail.cwd === "string") ? detail.cwd : "(none)"
      setRootState({ kind: "missing", cwd })
    }

    window.addEventListener("cmux:diff-changed", onDiff)
    window.addEventListener("turnDiff:diff", onDiff)
    window.addEventListener("cmux:status-changed", onStatus)
    window.addEventListener("turnDiff:rootChanged", onRoot)
    window.addEventListener("turnDiff:noGitRoot", onNoRoot)

    window.cmuxBridge?.post({ type: "ready" })

    return () => {
      window.removeEventListener("cmux:diff-changed", onDiff)
      window.removeEventListener("turnDiff:diff", onDiff)
      window.removeEventListener("cmux:status-changed", onStatus)
      window.removeEventListener("turnDiff:rootChanged", onRoot)
      window.removeEventListener("turnDiff:noGitRoot", onNoRoot)
    }
  }, [applyMultiDiff])

  // Track panel width via ResizeObserver so we can switch between the
  // unified (narrow) and side-by-side (wide) renderers without remounting
  // the whole tree on every pixel change.
  useEffect(() => {
    const node = panelRef.current
    if (!node || typeof ResizeObserver === "undefined") return
    const ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const w = entry.contentRect.width
        // Use a functional update + epsilon to avoid no-op rerenders.
        setPanelWidth((prev) => (Math.abs(prev - w) >= 1 ? w : prev))
      }
    })
    ro.observe(node)
    // Seed once synchronously so the first render after mount is correct.
    setPanelWidth(node.getBoundingClientRect().width)
    return () => ro.disconnect()
  }, [])

  const onToggleRepo = useCallback((root: string) => {
    setExpandedRepos((prev) => {
      const next = new Set(prev)
      if (next.has(root)) next.delete(root)
      else next.add(root)
      return next
    })
  }, [])

  const onToggleFile = useCallback((root: string) => {
    return (path: string) => {
      setRepos((prev) =>
        prev.map((entry) => {
          if (entry.root !== root) return entry
          const next = new Set(entry.expandedFiles)
          if (next.has(path)) next.delete(path)
          else next.add(path)
          return { ...entry, expandedFiles: next }
        })
      )
    }
  }, [])

  // Stable per-repo file-toggle handlers. Recompute when the repo set changes
  // so a removed repo's stale handler doesn't leak.
  const fileToggleHandlers = useMemo(() => {
    const map = new Map<string, (path: string) => void>()
    for (const entry of repos) map.set(entry.root, onToggleFile(entry.root))
    return map
  }, [repos, onToggleFile])

  const expandAllRepos = useCallback(() => {
    setExpandedRepos(new Set(repos.map((r) => r.root)))
  }, [repos])

  const collapseAllRepos = useCallback(() => {
    setExpandedRepos(new Set())
  }, [])

  const totalAdds = useMemo(
    () => repos.reduce((s, r) => s + r.files.reduce((sf, f) => sf + f.additions, 0), 0),
    [repos]
  )
  const totalDels = useMemo(
    () => repos.reduce((s, r) => s + r.files.reduce((sf, f) => sf + f.deletions, 0), 0),
    [repos]
  )
  const totalFiles = useMemo(
    () => repos.reduce((s, r) => s + r.files.length, 0),
    [repos]
  )

  // Empty states ----------------------------------------------------------

  if (repos.length === 0) {
    if (rootState.kind === "missing") {
      return (
        <div className="empty" ref={panelRef}>
          <div className="status-dot" data-status={status} />
          <p>No git repository detected. Make sure your work is inside a git repo.</p>
          <p className="muted"><code>{rootState.cwd}</code></p>
        </div>
      )
    }
    return (
      <div className="empty" ref={panelRef}>
        <div className="status-dot" data-status={status} />
        <p>{status === "Running" ? "Agent running…" : "No changes yet."}</p>
      </div>
    )
  }

  const allExpanded = expandedRepos.size === repos.length
  const anyExpanded = expandedRepos.size > 0
  const unified = panelWidth < UNIFIED_VIEW_WIDTH_THRESHOLD

  return (
    <div className="panel" ref={panelRef} data-layout={unified ? "unified" : "side-by-side"}>
      <header>
        <span className="status-dot" data-status={status} />
        <span className="title">Latest turn</span>
        <span className="totals">
          <span className="add-badge">+{totalAdds}</span>
          <span className="del-badge">−{totalDels}</span>
          <span className="file-count">{totalFiles} file{totalFiles === 1 ? "" : "s"}</span>
          <button
            type="button"
            className="bulk-toggle"
            onClick={allExpanded ? collapseAllRepos : expandAllRepos}
            aria-pressed={allExpanded}
            title={allExpanded ? "Collapse all repos" : "Expand all repos"}
          >
            {allExpanded ? "Collapse all" : anyExpanded ? "Expand all" : "Expand all"}
          </button>
        </span>
      </header>
      <div className="diff-body">
        {repos.map((entry) => (
          <RepoGroup
            key={entry.root}
            root={entry.root}
            files={entry.files}
            isActive={entry.isActive}
            expanded={expandedRepos.has(entry.root)}
            onToggleRepo={onToggleRepo}
            expandedFiles={entry.expandedFiles}
            onToggleFile={fileToggleHandlers.get(entry.root) ?? noop}
            unified={unified}
          />
        ))}
      </div>
    </div>
  )
}

// ---------- helpers ----------

function isRepoPayload(x: unknown): x is RepoPayload {
  if (!x || typeof x !== "object") return false
  const o = x as Record<string, unknown>
  return (
    typeof o.root === "string" &&
    typeof o.diff === "string" &&
    typeof o.isActive === "boolean"
  )
}

function parseDiffSafe(text: string): DiffFile[] {
  if (!text) return []
  try {
    return parseUnifiedDiff(text)
  } catch {
    return []
  }
}

function setEquals<T>(a: Set<T>, b: Set<T>): boolean {
  if (a.size !== b.size) return false
  for (const x of a) if (!b.has(x)) return false
  return true
}

function noop() {}
