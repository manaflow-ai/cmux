"use client"

import { useCallback } from "react"
import type { TreeNode, PaneGroup } from "../lib/split-tree"
import type { DropDirection } from "../lib/reducer"
import { GroupTabBar } from "./group-tab-bar"
import { SurfacePlaceholder } from "./surface-placeholder"
import { TerminalSurface } from "./terminal-surface"
import { SplitDivider } from "./split-divider"

interface SplitTreeViewProps {
  node: TreeNode
  groups: Record<string, PaneGroup>
  focusedGroupId: string
  onFocusGroup: (groupId: string) => void
  onResize: (splitId: string, ratio: number) => void
  onSelectTab: (groupId: string, tabId: string) => void
  onCloseTab: (groupId: string, tabId: string) => void
  onAddTab: (groupId: string) => void
  onTabDragStart?: (groupId: string, tabId: string, tabTitle: string, e: React.MouseEvent) => void
  draggedTabId?: string | null
  draggedSourceGroupId?: string | null
  tabBarDropGroupId?: string | null
  tabBarDropIndex?: number | null
  dropZone?: { groupId: string; direction: DropDirection } | null
}

export function SplitTreeView({
  node,
  groups,
  focusedGroupId,
  onFocusGroup,
  onResize,
  onSelectTab,
  onCloseTab,
  onAddTab,
  onTabDragStart,
  draggedTabId,
  draggedSourceGroupId,
  tabBarDropGroupId,
  tabBarDropIndex,
  dropZone,
}: SplitTreeViewProps) {
  const handleResize = useCallback(
    (splitId: string, ratio: number) => {
      onResize(splitId, ratio)
    },
    [onResize],
  )

  if (node.type === "leaf") {
    const group = groups[node.id]
    if (!group) return null
    const isFocused = node.id === focusedGroupId
    const activeTab = group.tabs.find((t) => t.id === group.activeTabId)
    const activeDropZone =
      dropZone && dropZone.groupId === node.id ? dropZone.direction : null

    return (
      <div
        data-testid={`group-${node.id}`}
        data-group-focused={isFocused}
        style={{
          display: "flex",
          flexDirection: "column",
          flex: 1,
          minWidth: 0,
          minHeight: 0,
        }}
      >
        <GroupTabBar
          group={group}
          isFocused={isFocused}
          onSelectTab={(tabId) => onSelectTab(node.id, tabId)}
          onCloseTab={(tabId) => onCloseTab(node.id, tabId)}
          onAddTab={() => onAddTab(node.id)}
          onTabDragStart={onTabDragStart}
          draggedTabId={draggedTabId}
          draggedSourceGroupId={draggedSourceGroupId}
          tabBarDropIndex={tabBarDropGroupId === node.id ? tabBarDropIndex : null}
        />
        {activeTab?.type === "terminal" ? (
          <TerminalSurface
            tabId={group.activeTabId}
            surfaceId={node.id}
            isFocused={isFocused}
            onFocus={() => onFocusGroup(node.id)}
            dropZone={activeDropZone}
          />
        ) : (
          <SurfacePlaceholder
            surfaceId={node.id}
            isFocused={isFocused}
            onFocus={() => onFocusGroup(node.id)}
            dropZone={activeDropZone}
          />
        )}
      </div>
    )
  }

  const isHorizontal = node.direction === "horizontal"
  const leftFlex = node.ratio
  const rightFlex = 1 - node.ratio

  return (
    <div
      data-testid={`split-${node.id}`}
      data-direction={node.direction}
      style={{
        display: "flex",
        flexDirection: isHorizontal ? "row" : "column",
        flex: 1,
        minWidth: 0,
        minHeight: 0,
      }}
    >
      <div style={{ flex: leftFlex, display: "flex", minWidth: 0, minHeight: 0 }}>
        <SplitTreeView
          node={node.left}
          groups={groups}
          focusedGroupId={focusedGroupId}
          onFocusGroup={onFocusGroup}
          onResize={handleResize}
          onSelectTab={onSelectTab}
          onCloseTab={onCloseTab}
          onAddTab={onAddTab}
          onTabDragStart={onTabDragStart}
          draggedTabId={draggedTabId}
          draggedSourceGroupId={draggedSourceGroupId}
          tabBarDropGroupId={tabBarDropGroupId}
          tabBarDropIndex={tabBarDropIndex}
          dropZone={dropZone}
        />
      </div>
      <SplitDivider
        direction={node.direction}
        splitId={node.id}
        onResize={handleResize}
      />
      <div style={{ flex: rightFlex, display: "flex", minWidth: 0, minHeight: 0 }}>
        <SplitTreeView
          node={node.right}
          groups={groups}
          focusedGroupId={focusedGroupId}
          onFocusGroup={onFocusGroup}
          onResize={handleResize}
          onSelectTab={onSelectTab}
          onCloseTab={onCloseTab}
          onAddTab={onAddTab}
          onTabDragStart={onTabDragStart}
          draggedTabId={draggedTabId}
          draggedSourceGroupId={draggedSourceGroupId}
          tabBarDropGroupId={tabBarDropGroupId}
          tabBarDropIndex={tabBarDropIndex}
          dropZone={dropZone}
        />
      </div>
    </div>
  )
}
