"use client"

import { useReducer, useEffect, useCallback, useState, useRef } from "react"
import { reducer, createInitialState, type DropDirection } from "./lib/reducer"
import { surfaceRegistry } from "./lib/surface-registry"
import { getLeaves } from "./lib/split-tree"
import { SplitTreeView } from "./components/split-tree-view"
import { Toolbar } from "./components/toolbar"
import { Sidebar } from "./components/sidebar"

// --- Drag state ---
interface DragInfo {
  sourceGroupId: string
  tabId: string
  tabTitle: string
  startX: number
  startY: number
  isDragging: boolean // true once mouse moves past threshold
}

type DropTarget = {
  type: "tab-bar"
  groupId: string
  index: number
} | {
  type: "pane"
  groupId: string
  direction: DropDirection
}

export function TerminalPage() {
  const [state, dispatch] = useReducer(reducer, null, createInitialState)

  // Sidebar state
  const [sidebarVisible, setSidebarVisible] = useState(true)
  const [sidebarWidth, setSidebarWidth] = useState(200)

  // Drag state
  const [dragInfo, setDragInfo] = useState<DragInfo | null>(null)
  const [dropTarget, setDropTarget] = useState<DropTarget | null>(null)
  const ghostRef = useRef<HTMLDivElement | null>(null)

  // Active workspace shorthand
  const ws = state.workspaces[state.activeWorkspaceId]

  // --- Per-pane tab handlers ---

  const handleSelectTab = useCallback((groupId: string, tabId: string) => {
    dispatch({ type: "SELECT_TAB", groupId, tabId })
  }, [])

  const handleCloseTab = useCallback((groupId: string, tabId: string) => {
    // Destroy terminal surface for the closed tab
    const group = ws.groups[groupId]
    if (group) {
      const tab = group.tabs.find((t) => t.id === tabId)
      if (tab?.type === "terminal") surfaceRegistry.destroy(tabId)
    }
    dispatch({ type: "CLOSE_TAB", groupId, tabId })
  }, [ws.groups])

  const handleAddTab = useCallback((groupId: string) => {
    dispatch({ type: "ADD_TAB", groupId })
  }, [])

  // --- Pane-level handlers ---

  const handleSplitRight = useCallback(() => {
    dispatch({ type: "SPLIT_PANE", groupId: ws.focusedGroupId, direction: "right" })
  }, [ws.focusedGroupId])

  const handleSplitDown = useCallback(() => {
    dispatch({ type: "SPLIT_PANE", groupId: ws.focusedGroupId, direction: "down" })
  }, [ws.focusedGroupId])

  const handleClear = useCallback(() => {
    const group = ws.groups[ws.focusedGroupId]
    if (group) surfaceRegistry.clearTerminal(group.activeTabId)
  }, [ws.focusedGroupId, ws.groups])

  const handleClosePane = useCallback(() => {
    const group = ws.groups[ws.focusedGroupId]
    if (!group) return
    // Destroy terminal surfaces in the pane
    for (const tab of group.tabs) {
      if (tab.type === "terminal") surfaceRegistry.destroy(tab.id)
    }
    dispatch({ type: "CLOSE_PANE", groupId: group.id })
  }, [ws.focusedGroupId, ws.groups])

  const handleEqualize = useCallback(() => {
    dispatch({ type: "EQUALIZE_SPLITS" })
  }, [])

  const handleResize = useCallback((splitId: string, ratio: number) => {
    dispatch({ type: "RESIZE_SPLIT", splitId, ratio })
  }, [])

  const handleFocusGroup = useCallback((groupId: string) => {
    dispatch({ type: "FOCUS_GROUP", groupId })
  }, [])

  const handleCloseWorkspace = useCallback((workspaceId: string) => {
    // Destroy all terminal surfaces in the workspace
    const targetWs = state.workspaces[workspaceId]
    if (targetWs) {
      for (const group of Object.values(targetWs.groups)) {
        for (const tab of group.tabs) {
          if (tab.type === "terminal") surfaceRegistry.destroy(tab.id)
        }
      }
    }
    dispatch({ type: "CLOSE_WORKSPACE", workspaceId })
  }, [state.workspaces])

  // --- Drag-and-drop ---

  const handleTabDragStart = useCallback((groupId: string, tabId: string, tabTitle: string, e: React.MouseEvent) => {
    setDragInfo({
      sourceGroupId: groupId,
      tabId,
      tabTitle,
      startX: e.clientX,
      startY: e.clientY,
      isDragging: false,
    })
  }, [])

  // Detect which drop target the mouse is over
  const detectTarget = useCallback((x: number, y: number): DropTarget | null => {
    // Check tab bars first
    const tabBars = document.querySelectorAll("[data-group-id]")
    for (const bar of tabBars) {
      const rect = bar.getBoundingClientRect()
      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
        const groupId = bar.getAttribute("data-group-id")!
        // Find insertion index based on x position
        const tabs = bar.querySelectorAll("[data-testid^='tab-']")
        let idx = tabs.length
        for (let i = 0; i < tabs.length; i++) {
          const tabRect = tabs[i].getBoundingClientRect()
          if (x < tabRect.left + tabRect.width / 2) {
            idx = i
            break
          }
        }
        return { type: "tab-bar", groupId, index: idx }
      }
    }

    // Check surfaces for directional drop zones
    const surfaces = document.querySelectorAll("[data-testid^='surface-']")
    for (const surface of surfaces) {
      const rect = surface.getBoundingClientRect()
      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
        const testId = surface.getAttribute("data-testid") ?? ""
        const surfaceId = testId.replace("surface-", "")
        // Determine direction based on position in surface
        const relX = (x - rect.left) / rect.width
        const relY = (y - rect.top) / rect.height
        let direction: DropDirection
        // Edges: 30% threshold
        if (relX < 0.3) direction = "left"
        else if (relX > 0.7) direction = "right"
        else if (relY < 0.3) direction = "up"
        else if (relY > 0.7) direction = "down"
        else continue // center — no drop zone
        return { type: "pane", groupId: surfaceId, direction }
      }
    }

    return null
  }, [])

  useEffect(() => {
    if (!dragInfo) return

    const handleMouseMove = (e: MouseEvent) => {
      const dx = e.clientX - dragInfo.startX
      const dy = e.clientY - dragInfo.startY
      if (!dragInfo.isDragging && Math.abs(dx) + Math.abs(dy) < 5) return

      if (!dragInfo.isDragging) {
        setDragInfo({ ...dragInfo, isDragging: true })
      }

      // Update ghost position
      if (ghostRef.current) {
        ghostRef.current.style.left = `${e.clientX + 12}px`
        ghostRef.current.style.top = `${e.clientY - 10}px`
      }

      // Detect drop target
      const target = detectTarget(e.clientX, e.clientY)
      setDropTarget(target)
    }

    const handleMouseUp = (e: MouseEvent) => {
      if (dragInfo.isDragging && dropTarget) {
        if (dropTarget.type === "tab-bar") {
          dispatch({
            type: "DRAG_TAB_TO_GROUP",
            fromGroupId: dragInfo.sourceGroupId,
            tabId: dragInfo.tabId,
            toGroupId: dropTarget.groupId,
            toIndex: dropTarget.index,
          })
        } else {
          dispatch({
            type: "DRAG_TAB_TO_PANE",
            fromGroupId: dragInfo.sourceGroupId,
            tabId: dragInfo.tabId,
            targetGroupId: dropTarget.groupId,
            direction: dropTarget.direction,
          })
        }
      } else if (!dragInfo.isDragging) {
        // Click without dragging — select the tab
        dispatch({ type: "SELECT_TAB", groupId: dragInfo.sourceGroupId, tabId: dragInfo.tabId })
      }
      setDragInfo(null)
      setDropTarget(null)
    }

    window.addEventListener("mousemove", handleMouseMove)
    window.addEventListener("mouseup", handleMouseUp)
    return () => {
      window.removeEventListener("mousemove", handleMouseMove)
      window.removeEventListener("mouseup", handleMouseUp)
    }
  }, [dragInfo, dropTarget, detectTarget])

  // Wire up OSC title changes from terminals
  useEffect(() => {
    surfaceRegistry.setTitleChangeHandler((tabId, title) => {
      dispatch({ type: "UPDATE_TAB_TITLE", tabId, title })
    })
  }, [])

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      const meta = e.metaKey
      const shift = e.shiftKey
      const ctrl = e.ctrlKey

      if (meta && !shift && !ctrl && e.key.toLowerCase() === "b") {
        e.preventDefault()
        e.stopPropagation()
        setSidebarVisible((v) => !v)
        return
      }
      if (meta && e.key.toLowerCase() === "d") {
        e.preventDefault()
        e.stopPropagation()
        if (shift) {
          handleSplitDown()
        } else {
          handleSplitRight()
        }
        return
      }
      if (ctrl && shift && e.key.toLowerCase() === "t") {
        e.preventDefault()
        e.stopPropagation()
        dispatch({ type: "ADD_WORKSPACE" })
        return
      }
      if (meta && !shift && e.key === "w") {
        e.preventDefault()
        e.stopPropagation()
        handleClosePane()
        return
      }
      if (meta && !shift && !ctrl && e.key === "k") {
        e.preventDefault()
        e.stopPropagation()
        handleClear()
        return
      }
      if (meta && e.key === "]") {
        e.preventDefault()
        e.stopPropagation()
        dispatch({ type: "NEXT_WORKSPACE" })
        return
      }
      if (meta && e.key === "[") {
        e.preventDefault()
        e.stopPropagation()
        dispatch({ type: "PREV_WORKSPACE" })
        return
      }
      if (meta && ctrl) {
        const k = e.key.toLowerCase()
        const dirMap: Record<string, "left" | "right" | "up" | "down"> = { h: "left", l: "right", k: "up", j: "down" }
        const dir = dirMap[k]
        if (dir) {
          e.preventDefault()
          e.stopPropagation()
          dispatch({ type: "FOCUS_DIRECTION", dir })
          return
        }
      }
      if (ctrl && !shift && e.key === "d") {
        e.preventDefault()
        e.stopPropagation()
        handleClosePane()
        return
      }
      if (ctrl && e.key === "Tab") {
        e.preventDefault()
        e.stopPropagation()
        if (shift) {
          dispatch({ type: "FOCUS_PREV_GROUP" })
        } else {
          dispatch({ type: "FOCUS_NEXT_GROUP" })
        }
        return
      }
    }

    window.addEventListener("keydown", handleKeyDown, true)
    return () => window.removeEventListener("keydown", handleKeyDown, true)
  }, [handleSplitRight, handleSplitDown, handleClosePane, handleClear])

  // Compute drag-related props for SplitTreeView
  const tabBarDropGroupId = dropTarget?.type === "tab-bar" ? dropTarget.groupId : null
  const tabBarDropIdx = dropTarget?.type === "tab-bar" ? dropTarget.index : null
  const paneDropZone = dropTarget?.type === "pane"
    ? { groupId: dropTarget.groupId, direction: dropTarget.direction }
    : null

  return (
    <div
      style={{
        display: "flex",
        width: "100vw",
        height: "100vh",
        background: "var(--background)",
        overflow: "hidden",
      }}
    >
      {sidebarVisible && (
        <Sidebar
          workspaces={state.workspaces}
          workspaceOrder={state.workspaceOrder}
          activeWorkspaceId={state.activeWorkspaceId}
          onSelectWorkspace={(id) => dispatch({ type: "SELECT_WORKSPACE", workspaceId: id })}
          onCloseWorkspace={handleCloseWorkspace}
          onAddWorkspace={() => dispatch({ type: "ADD_WORKSPACE" })}
          width={sidebarWidth}
          onResize={setSidebarWidth}
        />
      )}
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        {/* Render all workspaces, only show the active one */}
        <div data-testid="split-area" style={{ flex: 1, display: "flex", minHeight: 0 }}>
          <SplitTreeView
            node={ws.root}
            groups={ws.groups}
            focusedGroupId={ws.focusedGroupId}
            onFocusGroup={handleFocusGroup}
            onResize={handleResize}
            onSelectTab={handleSelectTab}
            onCloseTab={handleCloseTab}
            onAddTab={handleAddTab}
            onTabDragStart={handleTabDragStart}
            draggedTabId={dragInfo?.isDragging ? dragInfo.tabId : null}
            draggedSourceGroupId={dragInfo?.isDragging ? dragInfo.sourceGroupId : null}
            tabBarDropGroupId={tabBarDropGroupId}
            tabBarDropIndex={tabBarDropIdx}
            dropZone={paneDropZone}
          />
        </div>
        <Toolbar
          onSplitRight={handleSplitRight}
          onSplitDown={handleSplitDown}
          onClosePane={handleClosePane}
          onEqualize={handleEqualize}
        />
      </div>
      {/* Drag ghost */}
      {dragInfo?.isDragging && (
        <div
          data-testid="drag-ghost"
          ref={ghostRef}
          style={{
            position: "fixed",
            left: dragInfo.startX + 12,
            top: dragInfo.startY - 10,
            padding: "2px 8px",
            background: "var(--code-bg)",
            border: "1px solid var(--border)",
            borderRadius: 4,
            fontSize: 10,
            fontFamily: "var(--font-geist-sans)",
            color: "var(--foreground)",
            pointerEvents: "none",
            zIndex: 1000,
            whiteSpace: "nowrap",
            opacity: 0.9,
          }}
        >
          {dragInfo.tabTitle}
        </div>
      )}
    </div>
  )
}
