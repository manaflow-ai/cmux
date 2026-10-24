// Jump to latest while asks are open (Leo 2026-10-20, from Claude Code desktop): the floating
// button becomes a pill, the Needs you dot, "Needs your input" (or how many asks are open) and a
// down chevron. A press goes to the chat's own ask first (it waits at the foot of the chat), then
// cycles through the asks open elsewhere, newest first. With nothing open it is the plain button
// again. It reads the Needs you list (model.ts), never a signal of its own. Debug Settings
// `agentPane.debug.needsYouPill` (data-needs-you-pill="off") keeps the plain button.
import type { CSSProperties } from "react";
import { useT } from "../i18n";
import type { NeedsYouItem } from "./model";

export type TranscriptNeedsYou = {
  /// Every open ask, in this chat and elsewhere.
  count: number;
  /// Asks open in other chats: the pill shows even at the latest message, to go to them.
  elsewhere: number;
  /// After the press: `behind` is whether it also jumped to the latest message (this chat's ask).
  next(behind: boolean): void;
};

export function needsYouPillOn(
  root: { dataset: DOMStringMap } | undefined = globalThis.document?.documentElement,
): boolean {
  return root?.dataset.needsYouPill !== "off";
}

/// The order a press visits asks in: this chat's first, then the others, newest first.
export function pillOrder(items: readonly NeedsYouItem[], sessionId: string | undefined): NeedsYouItem[] {
  const here = items.filter((item) => item.sessionId === sessionId);
  return [...here, ...items.filter((item) => item.sessionId !== sessionId)];
}

/// The next ask a press goes to: with `behind`, the press already jumped to this chat's own ask, so
/// it stays; else the next ask elsewhere after `last` (the one the previous press went to).
export function nextAsk(
  items: readonly NeedsYouItem[],
  sessionId: string | undefined,
  behind: boolean,
  last: string | undefined,
): NeedsYouItem | undefined {
  const order = pillOrder(items, sessionId);
  if (behind && order[0]?.sessionId === sessionId) return undefined;
  const away = order.filter((item) => item.sessionId !== sessionId);
  if (away.length === 0) return undefined;
  const at = away.findIndex((item) => item.id === last);
  return away[(at + 1) % away.length];
}

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
