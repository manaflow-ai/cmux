"use client"

import type { DropDirection } from "../lib/reducer"

interface SurfacePlaceholderProps {
  surfaceId: string
  isFocused: boolean
  onFocus: () => void
  dropZone?: DropDirection | null
}

export function SurfacePlaceholder({
  surfaceId,
  isFocused,
  onFocus,
  dropZone,
}: SurfacePlaceholderProps) {
  return (
    <div
      data-testid={`surface-${surfaceId}`}
      data-focused={isFocused}
      data-drop-zone={dropZone ?? undefined}
      className="flex flex-1 items-center justify-center cursor-pointer select-none"
      style={{
        background: "var(--code-bg)",
        border: "none",
        borderRadius: 0,
        margin: 0,
        minWidth: 0,
        minHeight: 0,
        transition: "border-color 100ms",
        position: "relative",
        overflow: "hidden",
      }}
      onClick={onFocus}
    >
      <span
        style={{
          fontFamily: "var(--font-geist-mono)",
          fontSize: 13,
          color: "var(--muted)",
          opacity: 0.6,
        }}
      >
        {surfaceId}
      </span>
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
