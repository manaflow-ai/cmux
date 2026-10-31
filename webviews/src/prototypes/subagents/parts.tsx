// l10n-allow-file: gallery prototype parts (sample labels), not shipped UI.
// Shared pieces of the subagent prototypes: the status mark (the app's static status glyphs), the
// harness mark, the shimmer line, and the two frames: a cmux-next Mac window (skinny rail, one left
// sidebar, content) and an iPhone (cnx-ios language: true black or white, glass circles, 20 pt
// margins). Prototypes only: nothing here is wired to a store.
import type { ReactNode } from "react";
import { StatusGlyph } from "../../ui/StatusGlyph";
import type { StatusGlyphName } from "../../ui/statusGlyphs.generated";
import {
  buildForest,
  childrenOf,
  descendants,
  HARNESS_LABEL,
  STATE_LABEL,
  type AgentNode,
  type AgentState,
  type Harness,
} from "./hierarchy";

export type Platform = "mac" | "iphone";

const GLYPH: Record<AgentState, StatusGlyphName> = {
  running: "working",
  waiting: "permission",
  queued: "idle",
  done: "done",
  failed: "error",
  stopped: "idle",
};

/** The state as the app's static status glyph (shape tells the state; tint is the theme's). */
export function StatusMark({ state, size = 10, label = true }: { state: AgentState; size?: number; label?: boolean }) {
  return (
    <span className="sa-status" data-state={state}>
      <StatusGlyph name={GLYPH[state]} size={size} label={label ? STATE_LABEL[state] : undefined} />
    </span>
  );
}

/** The harness as a crisp circle with its initial (stands in for the harness's own mark). */
export function HarnessMark({ harness, size = 16 }: { harness: Harness; size?: number }) {
  return (
    <span
      className="sa-harness"
      data-harness={harness}
      style={{ width: size, height: size }}
      // tooltip-allow: the mark draws only the harness's initial; the title names the harness.
      title={HARNESS_LABEL[harness]}
      aria-hidden="true"
    >
      {HARNESS_LABEL[harness].slice(0, 1)}
    </span>
  );
}

/** A line of text with a moving highlight, as cnx-ios's WorkingLabel; static under Reduce Motion. */
export function Shimmer({ children, as = "span" }: { children: ReactNode; as?: "span" | "div" }) {
  const Tag = as;
  return <Tag className="sa-shimmer">{children}</Tag>;
}

/** Workspaces on the rail: crisp circles with a two-letter mark; the current one is ringed. */
const RAIL = ["cx", "io", "tu", "wb", "gh"];

/**
 * The cmux-next Mac window: a skinny rail (workspaces), one left sidebar, the content. `sidebar` is
 * as wide as it needs (the columns view widens it; that is the exception Lawrence asked for).
 */
export function MacWindow({
  sidebar,
  children,
  title,
  sidebarWidth = 260,
}: {
  sidebar: ReactNode;
  children: ReactNode;
  title: string;
  sidebarWidth?: number;
}) {
  return (
    <div className="sa-mac">
      <div className="sa-mac-titlebar">
        <span className="sa-traffic" aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
        <span className="sa-mac-title">{title}</span>
      </div>
      <div className="sa-mac-body">
        <nav className="sa-rail" aria-label="Workspaces">
          {RAIL.map((mark, index) => (
            <span key={mark} className="sa-rail-dot" data-current={index === 0 || undefined}>
              {mark}
            </span>
          ))}
        </nav>
        <aside className="sa-mac-sidebar" style={{ width: sidebarWidth }}>
          {sidebar}
        </aside>
        <main className="sa-mac-content">{children}</main>
      </div>
    </div>
  );
}

/** An iPhone 17 Pro (402 x 874 pt): status bar, then the screen. */
export function Phone({
  children,
  toolbar,
  bottom,
  overlay,
}: {
  children: ReactNode;
  toolbar?: ReactNode;
  /** Pinned under the screen (the composer). */
  bottom?: ReactNode;
  /** Over everything (a sheet). */
  overlay?: ReactNode;
}) {
  return (
    <div className="sa-phone-stage">
      <div className="sa-phone">
        <div className="sa-phone-status" aria-hidden="true">
          <span>9:41</span>
          <span className="sa-phone-island" />
          <span>100%</span>
        </div>
        {toolbar && <div className="sa-phone-toolbar">{toolbar}</div>}
        <div className="sa-phone-screen">{children}</div>
        {bottom}
        {overlay}
        <span className="sa-phone-home" aria-hidden="true" />
      </div>
    </div>
  );
}

/** A glass circle button of the iOS toolbar (44 pt), with an SF-Symbol-like glyph. */
export function GlassCircle({
  glyph,
  label,
  onClick,
}: {
  glyph: "back" | "menu" | "more" | "compose" | "close";
  label: string;
  onClick?: () => void;
}) {
  const paths: Record<typeof glyph, string> = {
    back: "M14 5 7 12l7 7",
    menu: "M5 8h14M5 12h14M5 16h14",
    more: "M6 12h.01M12 12h.01M18 12h.01",
    compose: "M4 20h4L19 9l-4-4L4 16v4Z",
    close: "M6 6l12 12M18 6 6 18",
  };
  return (
    <button type="button" className="sa-glass" aria-label={label} onClick={onClick}>
      <svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true">
        <path
          d={paths[glyph]}
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    </button>
  );
}

/** A small chevron, rotated when open. */
export function Chevron({ open }: { open: boolean }) {
  return (
    <svg
      className="sa-chevron"
      data-open={open || undefined}
      viewBox="0 0 12 12"
      width="10"
      height="10"
      aria-hidden="true"
    >
      <path
        d="M4 2.5 7.5 6 4 9.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

const CONTEXT = buildForest({ children: 8, depth: 2 });

/** The session list for context in the Mac sidebar (the sidebar layouts are their own entry). */
export function SessionList({ nodes = CONTEXT, current = "s1" }: { nodes?: readonly AgentNode[]; current?: string }) {
  return (
    <div className="sa-tree" data-platform="mac">
      {childrenOf(nodes, null).map((root) => (
        <div
          key={root.id}
          className="sa-row"
          data-platform="mac"
          data-selected={root.id === current || current.startsWith(`${root.id}.`) || undefined}
        >
          <StatusMark state={root.state} />
          <span className="sa-row-text">
            <span className="sa-row-title">{root.name}</span>
          </span>
          <span className="sa-row-meta">{descendants(nodes, root.id).length || ""}</span>
        </div>
      ))}
    </div>
  );
}
