import React, { useEffect, useState } from "react"
import { html as renderDiff2Html } from "diff2html"

type Status = "Idle" | "Running" | "Unknown"

export function App() {
  const [diff, setDiff] = useState<string>("")
  const [status, setStatus] = useState<Status>("Unknown")

  useEffect(() => {
    const onDiff = (e: Event) => setDiff((e as CustomEvent<string>).detail)
    const onStatus = (e: Event) => setStatus((e as CustomEvent<Status>).detail)
    window.addEventListener("cmux:diff-changed", onDiff)
    window.addEventListener("cmux:status-changed", onStatus)
    window.cmuxBridge?.post({ type: "ready" })
    return () => {
      window.removeEventListener("cmux:diff-changed", onDiff)
      window.removeEventListener("cmux:status-changed", onStatus)
    }
  }, [])

  if (!diff) {
    return (
      <div className="empty">
        <div className="status-dot" data-status={status} />
        <p>{status === "Running" ? "Agent running…" : "No changes yet."}</p>
      </div>
    )
  }

  return (
    <div className="panel">
      <header>
        <span className="status-dot" data-status={status} />
        <span className="title">Latest turn</span>
      </header>
      <div
        className="diff-body"
        dangerouslySetInnerHTML={{
          __html: renderDiff2Html(diff, {
            outputFormat: "line-by-line",
            drawFileList: true,
            matching: "lines",
          }),
        }}
      />
    </div>
  )
}
