// Pane header: scope pill (Branch ⌄ +130 -273), branch pill and the round toolbar.
import type { ReactNode } from "react";
import * as I from "../icons";
import { FULL_TOOLBAR, TOOLBAR_LABELS } from "../constants";
import type { ToolbarButtonId } from "../model";
import { anchorProps, type PaneAnchors } from "./TopLayer";

const flag = (on: boolean) => (on ? "" : undefined);

export function Counts({
  additions,
  deletions,
  alwaysBoth,
}: {
  additions: number;
  deletions: number;
  alwaysBoth?: boolean;
}) {
  return (
    <span className="cx-counts">
      {(alwaysBoth || additions > 0) && <span className="cx-add">+{additions}</span>}
      {(alwaysBoth || deletions > 0) && <span className="cx-del">-{deletions}</span>}
    </span>
  );
}

export function ScopePill({
  label,
  counts,
  open,
  anchor,
  onToggle,
}: {
  label: string;
  /** Totals after the button; null when no diff is loaded. */
  counts: { additions: number; deletions: number } | null;
  /** Scope menu open: the button is drawn pressed. */
  open: boolean;
  anchor: string;
  onToggle: () => void;
}) {
  return (
    <div className="cx-scope-pill">
      <button
        type="button"
        className="cx-scope-btn"
        aria-haspopup="menu"
        aria-expanded={open}
        data-open={flag(open)}
        onClick={onToggle}
        {...anchorProps(anchor)}
      >
        {label}
        <I.ChevronDown className="cx-scope-chevron" width={12} height={12} />
      </button>
      {counts && <Counts additions={counts.additions} deletions={counts.deletions} alwaysBoth />}
    </div>
  );
}

export function BranchPill({ head, base }: { head: string; base: string }) {
  return (
    <div className="cx-branch-pill">
      <span className="cx-branch-from">{head}</span>
      <I.ArrowRight className="cx-branch-arrow" width={12} height={12} />
      <span className="cx-branch-to">{base}</span>
      <I.ChevronDown className="cx-branch-chevron" width={12} height={12} />
    </div>
  );
}

const TOOL_ICONS: Record<ToolbarButtonId, ReactNode> = {
  options: <I.Dots />,
  jump: <I.FileSearch />,
  refresh: <I.Refresh />,
  wrap: <I.Wrap />,
  collapse: <I.CollapseAll />,
  split: <I.SplitView />,
  tree: <I.Panels />,
};

/**
 * The full toolbar. A narrow pane shows the compact group (⋯ or Refresh while refreshing,
 * Jump to file, tree; 30px apart) through a container query in changes.css.
 */
export interface ToolbarView {
  /** Toggled on (tree shown, wrap, split). */
  active: readonly ToolbarButtonId[];
  /** Button whose menu is open (drawn pressed). */
  pressed: ToolbarButtonId | null;
  focused: ToolbarButtonId | null;
  hovered: ToolbarButtonId | null;
  /** Refresh in progress: the refresh icon becomes a spinner. */
  refreshing: boolean;
}

export function Toolbar({
  view,
  anchors,
  onPress,
  onHover,
  onFocus,
}: {
  view: ToolbarView;
  anchors: PaneAnchors;
  onPress: (id: ToolbarButtonId) => void;
  onHover: (id: ToolbarButtonId | null) => void;
  onFocus: (id: ToolbarButtonId | null) => void;
}) {
  return (
    <div className="cx-toolgroup" role="toolbar" data-refreshing={flag(view.refreshing)}>
      {FULL_TOOLBAR.map(({ id, x }) => (
        <button
          key={id}
          type="button"
          className="cx-tool"
          aria-label={TOOLBAR_LABELS[id]}
          data-id={id}
          data-active={flag(view.active.includes(id))}
          data-pressed={flag(view.pressed === id)}
          data-focus={flag(view.focused === id)}
          data-hover={flag(view.hovered === id)}
          onClick={() => onPress(id)}
          onPointerEnter={() => onHover(id)}
          onPointerLeave={() => onHover(null)}
          onFocus={(e) => e.currentTarget.matches(":focus-visible") && onFocus(id)}
          onBlur={() => onFocus(null)}
          {...anchorProps(anchors.tool(id), { left: x - 14 })}
        >
          {id === "refresh" && view.refreshing ? <I.Spinner /> : TOOL_ICONS[id]}
        </button>
      ))}
    </div>
  );
}
