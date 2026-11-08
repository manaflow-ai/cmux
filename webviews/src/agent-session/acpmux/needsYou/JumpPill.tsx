// Jump to latest while asks are open (Leo 2026-10-20, from Claude Code desktop): the floating
// button becomes a pill, the Needs you dot, "Needs your input" (or how many asks are open) and a
// down chevron. A press goes to the chat's own ask first (it waits at the foot of the chat), then
// cycles through the asks of the chats it started, newest first. With nothing open it is the plain
// button again. It reads the Needs you list (model.ts), never a signal of its own. Debug Settings
// `agentPane.debug.needsYouPill` (data-needs-you-pill="off") keeps the plain button.
//
// The pill is this chat's button, so it speaks only for this chat and the agents it started
// (`pillAsks`). It used to count every ask acpmux reports anywhere, and show at the latest message
// for them: a Codex audit on Huge Blue that another chat's agent had started (no link to the chat on
// screen, on another computer, so this pane cannot answer it) turned Jump to latest into "Needs
// your input" in a chat where nothing waited on the person (Leo 2026-10-22: "it doesn't work rn").
// Every other chat's ask stays in the header's Needs you list and on its sidebar row.
import type { CSSProperties } from "react";
import { useT } from "../i18n";

export type TranscriptNeedsYou = {
  /// The open asks the pill speaks for: this chat's and its started chats' (`pillAsks`).
  count: number;
  /// Of those, the asks of the chats this chat started: the pill shows even at the latest message,
  /// to go to them.
  elsewhere: number;
  /// After the press: `behind` is whether it also jumped to the latest message (this chat's ask).
  next(behind: boolean): void;
};

export function NeedsYouPill({
  count,
  shown,
  lift,
  onJump,
}: {
  count: number;
  shown: boolean;
  lift: number;
  onJump(focused: boolean): void;
}) {
  const t = useT();
  const label = count > 1 ? t("needsYou.pillCount", { n: count }) : t("needsYou.pill");
  return (
    <button
      type="button"
      className="ui-glass ui-glass-floats acpmux-jump-latest acpmux-needs-you-pill"
      data-shown={shown ? "" : undefined}
      style={lift > 0 ? ({ "--acpmux-dock-space": `${lift}px` } as CSSProperties) : undefined}
      aria-label={label}
      inert={!shown}
      onClick={(event) => onJump(event.currentTarget === document.activeElement)}
    >
      <span className="acpmux-needs-you-dot" aria-hidden="true" />
      <span className="acpmux-needs-you-pill__label">{label}</span>
      <svg className="acpmux-needs-you-pill__chevron" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
        <path
          d="M3 4.5 6 7.5 9 4.5"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    </button>
  );
}
