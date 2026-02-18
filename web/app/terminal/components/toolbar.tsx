"use client"

interface ToolbarProps {
  onSplitRight: () => void
  onSplitDown: () => void
  onClosePane: () => void
  onEqualize: () => void
}

function ToolbarButton({
  label,
  shortcut,
  onClick,
  testId,
}: {
  label: string
  shortcut: string
  onClick: () => void
  testId?: string
}) {
  return (
    <button
      data-testid={testId}
      onClick={onClick}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 6,
        height: 26,
        padding: "0 8px",
        borderRadius: 4,
        border: "none",
        background: "transparent",
        color: "var(--muted)",
        fontSize: 12,
        fontFamily: "var(--font-geist-mono)",
        cursor: "pointer",
        transition: "background 80ms, color 80ms",
        whiteSpace: "nowrap",
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.background = "var(--code-bg)"
        e.currentTarget.style.color = "var(--foreground)"
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.background = "transparent"
        e.currentTarget.style.color = "var(--muted)"
      }}
    >
      <span>{label}</span>
      <span style={{ opacity: 0.5, fontSize: 11 }}>{shortcut}</span>
    </button>
  )
}

export function Toolbar({
  onSplitRight,
  onSplitDown,
  onClosePane,
  onEqualize,
}: ToolbarProps) {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        height: 32,
        borderTop: "1px solid var(--border)",
        background: "var(--background)",
        flexShrink: 0,
        paddingLeft: 4,
        paddingRight: 4,
        gap: 2,
      }}
    >
      <ToolbarButton testId="btn-split-right" label="Split →" shortcut="⌘D" onClick={onSplitRight} />
      <ToolbarButton testId="btn-split-down" label="Split ↓" shortcut="⌘⇧D" onClick={onSplitDown} />
      <ToolbarButton testId="btn-close-pane" label="Close" shortcut="⌃D" onClick={onClosePane} />
      <ToolbarButton testId="btn-equalize" label="Equalize" shortcut="" onClick={onEqualize} />
      <div style={{ flex: 1 }} />
      <span
        style={{
          fontSize: 11,
          fontFamily: "var(--font-geist-mono)",
          color: "var(--muted)",
          opacity: 0.4,
        }}
      >
        ⌘B sidebar · ⌃⇧T new tab · ⌘[] switch tabs · ⌃Tab cycle panes
      </span>
    </div>
  )
}
