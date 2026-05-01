import React, { useCallback, useEffect, useMemo, useState } from "react"
import { parseUnifiedDiff, type DiffFile } from "./diffModel"
import { DiffFileView } from "./DiffFileView"

type Status = "Idle" | "Running" | "Unknown"
type RootState =
  | { kind: "unknown" }
  | { kind: "ok"; root: string }
  | { kind: "missing"; cwd: string }

export function App() {
  const [diffText, setDiffText] = useState<string>("")
  const [status, setStatus] = useState<Status>("Unknown")
  const [rootState, setRootState] = useState<RootState>({ kind: "unknown" })
  const [expandedSet, setExpandedSet] = useState<Set<string>>(() => new Set())

  useEffect(() => {
    const onDiff = (e: Event) => {
      const detail = (e as CustomEvent).detail
      if (typeof detail === "string") {
        setDiffText(detail)
      } else if (detail && typeof detail.unifiedDiff === "string") {
        // Future-proofing for the structured `turnDiff:diff` payload shape.
        setDiffText(detail.unifiedDiff as string)
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
  }, [])

  const files: DiffFile[] = useMemo(() => {
    if (!diffText) return []
    try {
      return parseUnifiedDiff(diffText)
    } catch {
      return []
    }
  }, [diffText])

  // Drop expansion state for files that are no longer in the diff so the set
  // doesn't grow unbounded across turns.
  useEffect(() => {
    setExpandedSet((prev) => {
      if (prev.size === 0) return prev
      const live = new Set(files.map((f) => f.path))
      let changed = false
      const next = new Set<string>()
      for (const p of prev) {
        if (live.has(p)) next.add(p)
        else changed = true
      }
      return changed ? next : prev
    })
  }, [files])

  const onToggleFile = useCallback((path: string) => {
    setExpandedSet((prev) => {
      const next = new Set(prev)
      if (next.has(path)) next.delete(path)
      else next.add(path)
      return next
    })
  }, [])

  const expandAll = useCallback(() => {
    setExpandedSet(new Set(files.map((f) => f.path)))
  }, [files])

  const collapseAll = useCallback(() => {
    setExpandedSet(new Set())
  }, [])

  if (rootState.kind === "missing") {
    return (
      <div className="empty">
        <div className="status-dot" data-status={status} />
        <p>No git repository detected. Make sure your work is inside a git repo.</p>
        <p className="muted"><code>{rootState.cwd}</code></p>
      </div>
    )
  }

  const repoLabel: string | null = rootState.kind === "ok" ? rootState.root : null

  if (files.length === 0) {
    return (
      <div className="empty">
        <div className="status-dot" data-status={status} />
        {repoLabel && <p className="muted">Repo: <code>{repoLabel}</code></p>}
        <p>{status === "Running" ? "Agent running…" : "No changes yet."}</p>
      </div>
    )
  }

  const totalAdds = files.reduce((s, f) => s + f.additions, 0)
  const totalDels = files.reduce((s, f) => s + f.deletions, 0)
  const allExpanded = expandedSet.size === files.length
  const anyExpanded = expandedSet.size > 0

  return (
    <div className="panel">
      <header>
        <span className="status-dot" data-status={status} />
        <span className="title">Latest turn</span>
        <span className="totals">
          <span className="add-badge">+{totalAdds}</span>
          <span className="del-badge">−{totalDels}</span>
          <span className="file-count">{files.length} file{files.length === 1 ? "" : "s"}</span>
          <button
            type="button"
            className="bulk-toggle"
            onClick={allExpanded ? collapseAll : expandAll}
            aria-pressed={allExpanded}
            title={allExpanded ? "Collapse all files" : "Expand all files"}
          >
            {allExpanded ? "Collapse all" : anyExpanded ? "Expand all" : "Expand all"}
          </button>
        </span>
      </header>
      {repoLabel && (
        <div className="repo-header">Repo: <code>{repoLabel}</code></div>
      )}
      <div className="diff-body">
        {files.map((f) => (
          <DiffFileView
            key={f.path}
            file={f}
            expanded={expandedSet.has(f.path)}
            onToggle={onToggleFile}
          />
        ))}
      </div>
    </div>
  )
}
