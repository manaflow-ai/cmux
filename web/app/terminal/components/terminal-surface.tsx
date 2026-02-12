"use client"

import { useRef, useEffect } from "react"
import { surfaceRegistry } from "../lib/surface-registry"

import type { DropDirection } from "../lib/reducer"

interface TerminalSurfaceProps {
  tabId: string
  surfaceId: string
  isFocused: boolean
  onFocus: () => void
  dropZone?: DropDirection | null
}

export function TerminalSurface({
  tabId,
  surfaceId,
  isFocused,
  onFocus,
  dropZone,
}: TerminalSurfaceProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const isFocusedRef = useRef(isFocused)
  const readyRef = useRef(false)

  // Keep ref in sync so the create callback sees the latest value
  isFocusedRef.current = isFocused

  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    let cancelled = false
    readyRef.current = false

    surfaceRegistry.create(tabId).then((entry) => {
      if (cancelled) return
      container.appendChild(entry.containerEl)
      requestAnimationFrame(() => {
        if (cancelled) return
        entry.adapter.fit()
        entry.adapter.observeResize()
        surfaceRegistry.connect(tabId)
        readyRef.current = true
        // Apply focus state that may have been set before terminal was ready
        surfaceRegistry.setFocused(tabId, isFocusedRef.current)
      })
    })

    return () => {
      cancelled = true
      readyRef.current = false
      // Detach but don't destroy — terminal survives tab switches
      const entry = surfaceRegistry.get(tabId)
      if (entry && container.contains(entry.containerEl)) {
        container.removeChild(entry.containerEl)
      }
    }
  }, [tabId])

  useEffect(() => {
    // Only apply if the terminal is already created; otherwise the create
    // callback above will apply the initial focus state.
    if (readyRef.current) {
      surfaceRegistry.setFocused(tabId, isFocused)
    }
  }, [isFocused, tabId])

  return (
    <div
      data-testid={`surface-${surfaceId}`}
      data-focused={isFocused}
      data-drop-zone={dropZone ?? undefined}
      className="flex flex-1 cursor-text select-none"
      style={{
        background: "#171717",
        border: "none",
        borderRadius: 0,
        margin: 0,
        minWidth: 0,
        minHeight: 0,
        position: "relative",
        overflow: "hidden",
      }}
      onClick={onFocus}
    >
      <div ref={containerRef} style={{ width: "100%", height: "100%" }} />
      {dropZone && <DropZoneOverlay direction={dropZone} />}
    </div>
  )
}

function DropZoneOverlay({ direction }: { direction: DropDirection }) {
  const pos: React.CSSProperties = {
    position: "absolute",
    background: "rgba(59, 130, 246, 0.15)",
    border: "2px solid rgba(59, 130, 246, 0.4)",
    borderRadius: 4,
    zIndex: 10,
    pointerEvents: "none",
  }
  switch (direction) {
    case "left":
      return <div data-testid={`drop-indicator-${direction}`} style={{ ...pos, top: 4, bottom: 4, left: 4, width: "45%" }} />
    case "right":
      return <div data-testid={`drop-indicator-${direction}`} style={{ ...pos, top: 4, bottom: 4, right: 4, width: "45%" }} />
    case "up":
      return <div data-testid={`drop-indicator-${direction}`} style={{ ...pos, left: 4, right: 4, top: 4, height: "45%" }} />
    case "down":
      return <div data-testid={`drop-indicator-${direction}`} style={{ ...pos, left: 4, right: 4, bottom: 4, height: "45%" }} />
  }
}
