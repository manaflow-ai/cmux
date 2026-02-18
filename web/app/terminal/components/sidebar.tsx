"use client"

import { useState, useCallback, useRef } from "react"
import type { Workspace } from "../lib/split-tree"

interface SidebarProps {
  workspaces: Record<string, Workspace>
  workspaceOrder: string[]
  activeWorkspaceId: string
  onSelectWorkspace: (workspaceId: string) => void
  onCloseWorkspace: (workspaceId: string) => void
  onAddWorkspace: () => void
  width: number
  onResize: (width: number) => void
}

const MIN_WIDTH = 160
const MAX_WIDTH = 400

export function Sidebar({
  workspaces,
  workspaceOrder,
  activeWorkspaceId,
  onSelectWorkspace,
  onCloseWorkspace,
  onAddWorkspace,
  width,
  onResize,
}: SidebarProps) {
  const [hoveredId, setHoveredId] = useState<string | null>(null)
  const resizing = useRef(false)
  const startX = useRef(0)
  const startW = useRef(0)

  const handleResizeStart = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault()
      resizing.current = true
      startX.current = e.clientX
      startW.current = width

      const onMove = (ev: MouseEvent) => {
        if (!resizing.current) return
        const delta = ev.clientX - startX.current
        const newWidth = Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, startW.current + delta))
        onResize(newWidth)
      }
      const onUp = () => {
        resizing.current = false
        document.removeEventListener("mousemove", onMove)
        document.removeEventListener("mouseup", onUp)
        document.body.style.cursor = ""
        document.body.style.userSelect = ""
      }
      document.body.style.cursor = "col-resize"
      document.body.style.userSelect = "none"
      document.addEventListener("mousemove", onMove)
      document.addEventListener("mouseup", onUp)
    },
    [width, onResize],
  )

  return (
    <div
      style={{
        width,
        minWidth: MIN_WIDTH,
        maxWidth: MAX_WIDTH,
        height: "100%",
        display: "flex",
        flexDirection: "column",
        background: "#1C1C1E",
        borderRight: "1px solid #2C2C2E",
        flexShrink: 0,
        position: "relative",
        userSelect: "none",
      }}
    >
      {/* Header */}
      <div
        style={{
          padding: "12px 14px 8px",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          flexShrink: 0,
        }}
      >
        <span
          style={{
            fontSize: 11,
            fontWeight: 600,
            fontFamily: "var(--font-geist-sans)",
            color: "#8E8E93",
            textTransform: "uppercase",
            letterSpacing: "0.5px",
          }}
        >
          Tabs
        </span>
        <span
          onClick={onAddWorkspace}
          style={{
            display: "inline-flex",
            alignItems: "center",
            justifyContent: "center",
            width: 20,
            height: 20,
            borderRadius: 4,
            fontSize: 16,
            lineHeight: 1,
            color: "#8E8E93",
            cursor: "pointer",
            transition: "color 80ms",
          }}
          onMouseEnter={(e) => { e.currentTarget.style.color = "#FFFFFF" }}
          onMouseLeave={(e) => { e.currentTarget.style.color = "#8E8E93" }}
        >
          +
        </span>
      </div>

      {/* Workspace list */}
      <div
        style={{
          flex: 1,
          overflowY: "auto",
          overflowX: "hidden",
          padding: "0 6px 8px",
        }}
      >
        {workspaceOrder.map((wsId) => {
          const ws = workspaces[wsId]
          if (!ws) return null
          const isActive = wsId === activeWorkspaceId
          const isHovered = hoveredId === wsId
          return (
            <div
              key={wsId}
              onClick={() => onSelectWorkspace(wsId)}
              onMouseEnter={() => setHoveredId(wsId)}
              onMouseLeave={() => setHoveredId(null)}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 8,
                padding: "7px 10px",
                marginBottom: 1,
                borderRadius: 6,
                cursor: "pointer",
                background: isActive
                  ? "#007AFF"
                  : isHovered
                    ? "rgba(255, 255, 255, 0.06)"
                    : "transparent",
                transition: "background 80ms",
              }}
            >
              {/* Terminal icon */}
              <svg
                width="12"
                height="12"
                viewBox="0 0 16 16"
                fill="none"
                style={{ flexShrink: 0, opacity: isActive ? 1 : 0.5 }}
              >
                <path
                  d="M2 3.5L6.5 8L2 12.5"
                  stroke={isActive ? "#FFFFFF" : "#A3A3A3"}
                  strokeWidth="1.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
                <path
                  d="M8.5 12.5H14"
                  stroke={isActive ? "#FFFFFF" : "#A3A3A3"}
                  strokeWidth="1.5"
                  strokeLinecap="round"
                />
              </svg>

              {/* Title */}
              <span
                style={{
                  flex: 1,
                  fontSize: 12,
                  fontFamily: "var(--font-geist-sans)",
                  color: isActive ? "#FFFFFF" : "#E5E5E5",
                  whiteSpace: "nowrap",
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                  lineHeight: 1.3,
                }}
              >
                {ws.title}
              </span>

              {/* Close button */}
              {isHovered && workspaceOrder.length > 1 && (
                <span
                  onClick={(e) => {
                    e.stopPropagation()
                    onCloseWorkspace(wsId)
                  }}
                  style={{
                    display: "inline-flex",
                    alignItems: "center",
                    justifyContent: "center",
                    width: 16,
                    height: 16,
                    borderRadius: 3,
                    fontSize: 10,
                    lineHeight: 1,
                    color: isActive ? "rgba(255,255,255,0.7)" : "#8E8E93",
                    cursor: "pointer",
                    flexShrink: 0,
                  }}
                  onMouseEnter={(e) => {
                    e.currentTarget.style.color = "#FFFFFF"
                    e.currentTarget.style.background = "rgba(255,255,255,0.1)"
                  }}
                  onMouseLeave={(e) => {
                    e.currentTarget.style.color = isActive ? "rgba(255,255,255,0.7)" : "#8E8E93"
                    e.currentTarget.style.background = "transparent"
                  }}
                >
                  ✕
                </span>
              )}
            </div>
          )
        })}
      </div>

      {/* Resize handle */}
      <div
        onMouseDown={handleResizeStart}
        style={{
          position: "absolute",
          top: 0,
          right: -3,
          width: 6,
          height: "100%",
          cursor: "col-resize",
          zIndex: 10,
        }}
      />
    </div>
  )
}
