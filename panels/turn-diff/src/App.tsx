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

/** localStorage key for the user's manual repo ordering. Single-instance, so
 *  one key is enough — each cmux process has its own WKWebView storage. */
const USER_ORDER_STORAGE_KEY = "turn-diff-repo-order"

export function App() {
  const [repos, setRepos] = useState<RepoEntry[]>([])
  const [status, setStatus] = useState<Status>("Unknown")
  const [rootState, setRootState] = useState<RootState>({ kind: "unknown" })
  const [expandedRepos, setExpandedRepos] = useState<Set<string>>(() => new Set())
  const [panelWidth, setPanelWidth] = useState<number>(() =>
    typeof window !== "undefined" ? window.innerWidth : UNIFIED_VIEW_WIDTH_THRESHOLD
  )
  /** User-defined ordering of repo groups, keyed by repo root. Lower = higher
   *  in the list. Repos without an entry render in their incoming Swift order
   *  AFTER ordered ones. Hydrated from localStorage on mount; persisted on
   *  every reorder. `null` means "not hydrated yet" (only true synchronously
   *  during the first render); becomes `{}` after hydration if storage is
   *  empty. */
  const [userOrderByRoot, setUserOrderByRoot] = useState<Record<string, number> | null>(
    () => loadUserOrder()
  )
  /** Root currently being dragged; null when no drag is active. */
  const [draggingRoot, setDraggingRoot] = useState<string | null>(null)
  /** Root currently under the pointer during a drag (drop target). */
  const [dropTargetRoot, setDropTargetRoot] = useState<string | null>(null)
  const panelRef = useRef<HTMLDivElement | null>(null)
  /** Tracks which repos we've already seen so newly-discovered repos can pick
   *  up the right default expansion state (only the active one is expanded). */
  const seenReposRef = useRef<Set<string>>(new Set())
  /** Mirrors `repos` for synchronous reads in callbacks (drag-to-reorder). We
   *  can't read state from inside `useCallback` deps without re-binding the
   *  callback every render, and using `setRepos(r => r)` as a sync reader is
   *  fragile under React's concurrent features. */
  const reposRef = useRef<RepoEntry[]>([])

  // Keep reposRef in sync with state so callbacks can read the latest list
  // synchronously without re-binding on every change to `repos`.
  useEffect(() => {
    reposRef.current = repos
  }, [repos])

  // Persist user order whenever it changes (after initial hydration).
  useEffect(() => {
    if (userOrderByRoot === null) return
    try {
      window.localStorage.setItem(
        USER_ORDER_STORAGE_KEY,
        JSON.stringify(userOrderByRoot)
      )
    } catch {
      // Quota / disabled storage — silently ignore. Order falls back to
      // Swift-provided incoming order on next mount.
    }
  }, [userOrderByRoot])

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

  // ---------- Drag-to-reorder ----------

  const onDragStart = useCallback((root: string) => {
    setDraggingRoot(root)
  }, [])

  const onDragOver = useCallback((root: string) => {
    setDropTargetRoot((prev) => (prev === root ? prev : root))
  }, [])

  const onDragEnd = useCallback(() => {
    setDraggingRoot(null)
    setDropTargetRoot(null)
  }, [])

  /** Commit a reorder: move `from` so it sits in the slot currently occupied
   *  by `to`. We compute against the CURRENT visible (display-ordered) list
   *  so the user sees what they moved. After the swap, write a fresh
   *  userOrderByRoot map mirroring the new index for every visible repo. */
  const onDrop = useCallback((targetRoot: string) => {
    setDraggingRoot((dragging) => {
      if (!dragging || dragging === targetRoot) {
        setDropTargetRoot(null)
        return null
      }
      setUserOrderByRoot((prevOrder) => {
        const order = prevOrder ?? {}
        // Read the latest repo list from the ref. The ref is kept in sync by
        // the effect above; this is safe under React's concurrent features
        // (unlike the previous `setRepos(r => r)` reader trick).
        const display = sortReposByUserOrder(reposRef.current, order)
        const fromIdx = display.findIndex((e) => e.root === dragging)
        const toIdx = display.findIndex((e) => e.root === targetRoot)
        if (fromIdx < 0 || toIdx < 0 || fromIdx === toIdx) return prevOrder
        const reordered = [...display]
        const [moved] = reordered.splice(fromIdx, 1)
        reordered.splice(toIdx, 0, moved)
        // Materialize: assign a contiguous integer to every visible repo so
        // future renders are stable even when Swift's incoming order shifts.
        const next: Record<string, number> = { ...order }
        reordered.forEach((entry, idx) => {
          next[entry.root] = idx
        })
        return next
      })
      setDropTargetRoot(null)
      return null
    })
  }, [])

  // ---------- Display order ----------

  /** Repos in the order we actually render them: user order (if set) wins,
   *  remaining repos fall through in incoming Swift (append-only) order. */
  const displayRepos = useMemo(
    () => sortReposByUserOrder(repos, userOrderByRoot ?? {}),
    [repos, userOrderByRoot]
  )

  const expandAllRepos = useCallback(() => {
    setExpandedRepos(new Set(displayRepos.map((r) => r.root)))
  }, [displayRepos])

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
        {displayRepos.map((entry) => (
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
            onDragStart={onDragStart}
            onDragOver={onDragOver}
            onDrop={onDrop}
            onDragEnd={onDragEnd}
            isDragging={draggingRoot === entry.root}
            isDropTarget={
              dropTargetRoot === entry.root && draggingRoot !== null && draggingRoot !== entry.root
            }
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

/** Stable sort: ordered repos first (by ascending userOrder index), then any
 *  repos without a user order in their original incoming Swift order. */
function sortReposByUserOrder(
  repos: RepoEntry[],
  order: Record<string, number>
): RepoEntry[] {
  if (Object.keys(order).length === 0) return repos
  const ordered: RepoEntry[] = []
  const unordered: RepoEntry[] = []
  for (const entry of repos) {
    if (Object.prototype.hasOwnProperty.call(order, entry.root)) {
      ordered.push(entry)
    } else {
      unordered.push(entry)
    }
  }
  ordered.sort((a, b) => order[a.root]! - order[b.root]!)
  return ordered.concat(unordered)
}

/** Hydrate user ordering from localStorage. Returns `{}` (empty map) when
 *  storage is unavailable or contains nothing — never `null`, since we want
 *  the persistence effect to run unconditionally on user reorder. */
function loadUserOrder(): Record<string, number> {
  if (typeof window === "undefined") return {}
  try {
    const raw = window.localStorage.getItem(USER_ORDER_STORAGE_KEY)
    if (!raw) return {}
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {}
    const out: Record<string, number> = {}
    for (const [k, v] of Object.entries(parsed)) {
      if (typeof k === "string" && typeof v === "number" && Number.isFinite(v)) {
        out[k] = v
      }
    }
    return out
  } catch {
    return {}
  }
}
