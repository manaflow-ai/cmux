"use client"

import { useCallback, useRef } from "react"

interface SplitDividerProps {
  direction: "horizontal" | "vertical"
  splitId: string
  onResize: (splitId: string, ratio: number) => void
}

export function SplitDivider({
  direction,
  splitId,
  onResize,
}: SplitDividerProps) {
  const rafRef = useRef<number>(0)
  const containerRef = useRef<HTMLDivElement>(null)

  const handleMouseDown = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault()
      const divider = containerRef.current
      if (!divider) return
      const parent = divider.parentElement
      if (!parent) return

      const rect = parent.getBoundingClientRect()
      const isHorizontal = direction === "horizontal"

      const onMouseMove = (moveEvent: MouseEvent) => {
        cancelAnimationFrame(rafRef.current)
        rafRef.current = requestAnimationFrame(() => {
          const pos = isHorizontal ? moveEvent.clientX : moveEvent.clientY
          const start = isHorizontal ? rect.left : rect.top
          const size = isHorizontal ? rect.width : rect.height
          const ratio = (pos - start) / size
          onResize(splitId, ratio)
        })
      }

      const onMouseUp = () => {
        cancelAnimationFrame(rafRef.current)
        document.removeEventListener("mousemove", onMouseMove)
        document.removeEventListener("mouseup", onMouseUp)
        document.body.style.cursor = ""
        document.body.style.userSelect = ""
      }

      document.body.style.cursor = isHorizontal ? "col-resize" : "row-resize"
      document.body.style.userSelect = "none"
      document.addEventListener("mousemove", onMouseMove)
      document.addEventListener("mouseup", onMouseUp)
    },
    [direction, splitId, onResize],
  )

  const isHorizontal = direction === "horizontal"

  return (
    <div
      ref={containerRef}
      data-testid={`divider-${splitId}`}
      data-direction={direction}
      onMouseDown={handleMouseDown}
      style={{
        flexShrink: 0,
        cursor: isHorizontal ? "col-resize" : "row-resize",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        width: isHorizontal ? 8 : "100%",
        height: isHorizontal ? "100%" : 8,
        margin: isHorizontal ? "0 -3.5px" : "-3.5px 0",
        zIndex: 1,
      }}
    >
      <div
        style={{
          background: "var(--border)",
          borderRadius: 1,
          width: isHorizontal ? 1 : "100%",
          height: isHorizontal ? "100%" : 1,
        }}
      />
    </div>
  )
}
