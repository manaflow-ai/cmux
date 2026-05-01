import React, { useEffect, useMemo, useState } from "react"
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

  if (rootState.kind === "missing") {
    return (
      <div className="empty">
        <div className="status-dot" data-status={status} />
        <p>No git repository at <code>{rootState.cwd}</code></p>
      </div>
    )
  }

  if (files.length === 0) {
    return (
      <div className="empty">
        <div className="status-dot" data-status={status} />
        <p>{status === "Running" ? "Agent running…" : "No changes yet."}</p>
      </div>
    )
  }

  const totalAdds = files.reduce((s, f) => s + f.additions, 0)
  const totalDels = files.reduce((s, f) => s + f.deletions, 0)

  return (
    <div className="panel">
      <header>
        <span className="status-dot" data-status={status} />
        <span className="title">Latest turn</span>
        <span className="totals">
          <span className="add-badge">+{totalAdds}</span>
          <span className="del-badge">−{totalDels}</span>
          <span className="file-count">{files.length} file{files.length === 1 ? "" : "s"}</span>
        </span>
      </header>
      <div className="diff-body">
        {files.map((f) => (
          <DiffFileView key={f.path} file={f} />
        ))}
      </div>
    </div>
  )
}
