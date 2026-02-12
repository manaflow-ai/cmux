"use client"

import type { PaneGroup } from "../lib/split-tree"

interface GroupTabBarProps {
  group: PaneGroup
  isFocused: boolean
  onSelectTab: (tabId: string) => void
  onCloseTab: (tabId: string) => void
  onAddTab: () => void
  onTabDragStart?: (groupId: string, tabId: string, tabTitle: string, e: React.MouseEvent) => void
  draggedTabId?: string | null
  draggedSourceGroupId?: string | null
  tabBarDropIndex?: number | null
}

export function GroupTabBar({
  group,
  isFocused,
  onSelectTab,
  onCloseTab,
  onAddTab,
  onTabDragStart,
  draggedTabId,
  draggedSourceGroupId,
  tabBarDropIndex,
}: GroupTabBarProps) {
  return (
    <div
      data-testid={`group-tab-bar-${group.id}`}
      data-group-id={group.id}
      style={{
        display: "flex",
        alignItems: "stretch",
        height: 28,
        borderBottom: "1px solid var(--border)",
        background: "var(--background)",
        flexShrink: 0,
        gap: 0,
        overflow: "hidden",
        position: "relative",
      }}
    >
      {group.tabs.map((tab, i) => {
        const isActive = tab.id === group.activeTabId
        const isDragged = tab.id === draggedTabId && group.id === draggedSourceGroupId
        return (
          <div
            key={tab.id}
            data-testid={`tab-${tab.id}`}
            data-active={isActive}
            style={{
              position: "relative",
              display: "flex",
              alignItems: "center",
            }}
          >
            {tabBarDropIndex === i && (
              <div
                data-testid="tab-drop-indicator"
                style={{
                  position: "absolute",
                  left: -1,
                  top: 4,
                  bottom: 4,
                  width: 2,
                  background: "var(--surface-focused)",
                  borderRadius: 1,
                  zIndex: 2,
                }}
              />
            )}
            <div
              onMouseDown={(e) => {
                if (e.button === 0 && onTabDragStart) {
                  onTabDragStart(group.id, tab.id, tab.title, e)
                }
              }}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 4,
                padding: "0 8px",
                height: "100%",
                cursor: isDragged ? "grabbing" : "pointer",
                fontSize: 10,
                fontFamily: "var(--font-geist-sans)",
                background: isActive ? "var(--code-bg)" : "transparent",
                borderTop: isActive && isFocused ? "2px solid #3b82f6" : "2px solid transparent",
                color: isActive ? "var(--foreground)" : "var(--muted)",
                flexShrink: 0,
                userSelect: "none",
                borderRight: "1px solid var(--border)",
                transition: "background 80ms, color 80ms",
                opacity: isDragged ? 0.4 : 1,
              }}
              onMouseEnter={(e) => {
                if (!isActive && !isDragged) e.currentTarget.style.background = "var(--code-bg)"
              }}
              onMouseLeave={(e) => {
                if (!isActive && !isDragged) e.currentTarget.style.background = "transparent"
              }}
            >
              <span>{tab.title}</span>
              {group.tabs.length > 1 && (
                <span
                  data-testid={`tab-close-${tab.id}`}
                  onClick={(e) => {
                    e.stopPropagation()
                    onCloseTab(tab.id)
                  }}
                  style={{
                    display: "inline-flex",
                    alignItems: "center",
                    justifyContent: "center",
                    width: 14,
                    height: 14,
                    borderRadius: 2,
                    fontSize: 12,
                    lineHeight: 1,
                    color: "var(--muted)",
                    cursor: "pointer",
                    opacity: 0.6,
                  }}
                  onMouseEnter={(e) => {
                    e.currentTarget.style.color = "var(--foreground)"
                    e.currentTarget.style.opacity = "1"
                  }}
                  onMouseLeave={(e) => {
                    e.currentTarget.style.color = "var(--muted)"
                    e.currentTarget.style.opacity = "0.6"
                  }}
                >
                  x
                </span>
              )}
            </div>
          </div>
        )
      })}
      {tabBarDropIndex === group.tabs.length && (
        <div
          data-testid="tab-drop-indicator"
          style={{
            position: "relative",
            width: 2,
            marginTop: 4,
            marginBottom: 4,
            background: "var(--surface-focused)",
            borderRadius: 1,
            flexShrink: 0,
          }}
        />
      )}
      <div
        data-testid={`add-tab-button-${group.id}`}
        onClick={onAddTab}
        style={{
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          width: 28,
          height: 28,
          cursor: "pointer",
          fontSize: 14,
          color: "var(--muted)",
          flexShrink: 0,
          userSelect: "none",
          opacity: 0.6,
          transition: "opacity 80ms",
        }}
        onMouseEnter={(e) => {
          e.currentTarget.style.opacity = "1"
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.opacity = "0.6"
        }}
      >
        +
      </div>
    </div>
  )
}
