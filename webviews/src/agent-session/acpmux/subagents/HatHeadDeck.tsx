// The composer hat's top bar as something to thumb through (hatHeader.experiment.ts `strip` and
// `cards`; Leo, 2026-11-20: "we need to be able to like thumb through them like a Rolodex or whatever
// at the top ... you hover over it, and then on each one, it's like there's a slight pop ... perhaps
// the text itself maybe changes like on the top of the composer hat ... you mouse over it, and then
// you can just go and go and go"). One mark per running line, in the header's icon slot: its harness's
// (Claude, Codex, ...), a started chat's, or a command's terminal. Pointing at a mark names its line
// in the header's words (SubagentTray.tsx `peek`); the marks touch, so running the pointer along them
// never falls back to the summary between two; leaving the deck gives the summary back. A click on a
// mark opens its line and stops there, so it never also folds the hat.
//
// The marks are pointer twins of the list's lines (aria-hidden): the header button stays the one
// keyboard control, and the open list reaches each line, as the stacked marks do today.
import { type CSSProperties, type RefObject, type WheelEvent, useLayoutEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { AgentIdentity } from "./AgentIdentity";
import { SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { agentTone } from "./agentTones";
import { SILENT_TURN_ICON, trayItemKey, type TrayItem } from "./runningTray";

const ROW_ICON = rowIconSize(12);

/// The most marks the deck draws; the rest are "+N more", which opens the hat like the header does.
export const DECK_MARKS = 8;
/// How far the wheel goes for one card (the `cards` look): a trackpad's stream of small deltas moves
/// one card per notch's worth, never one per event.
const WHEEL_STEP = 24;

/// Whether the deck fits its row beside the whole sentence (Leo, 2026-11-27, on the marks and "+2 more"
/// after "10 subagents working": "should we compact these and drop them away in favour of text when
/// things shrink?"). A measured fit, never a fixed count: the room the header has, less everything else
/// in its flow with the words at their natural width, against the deck's own width. A deck that does not
/// fit is laid out off the row (`data-fit="off"`, so it stays measurable) and the words keep the row. The
/// room never depends on the deck's own state, so the answer never flaps at a boundary.
function useDeckFit(deck: RefObject<HTMLSpanElement | null>, signature: string, measured: boolean): boolean {
  const [fits, setFits] = useState(true);
  useLayoutEffect(() => {
    const node = deck.current;
    const head = node?.closest<HTMLElement>(".acpmux-running-tray__head");
    if (!node || !head || !measured) return undefined;
    const fit = () => {
      const style = getComputedStyle(head);
      const gap = Number.parseFloat(style.columnGap) || 0;
      let used = Number.parseFloat(style.paddingLeft) + Number.parseFloat(style.paddingRight);
      let count = 0;
      for (const child of Array.from(head.children) as HTMLElement[]) {
        if (child === node) continue;
        const box = getComputedStyle(child);
        if (box.position === "absolute" || box.display === "none") continue;
        const own = child.classList.contains("acpmux-running-tray__title") ? child.scrollWidth : child.offsetWidth;
        used += own + Number.parseFloat(box.marginLeft) + Number.parseFloat(box.marginRight);
        count += 1;
      }
      const deckStyle = getComputedStyle(node);
      const wanted =
        Math.max(node.offsetWidth, node.scrollWidth) +
        Number.parseFloat(deckStyle.marginLeft) +
        Number.parseFloat(deckStyle.marginRight) +
        gap;
      setFits(used + gap * count + wanted <= head.clientWidth + 0.5);
    };
    fit();
    if (typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver(fit);
    observer.observe(head);
    // The words change (a count ticks, a name joins): the room they want does, though the row's box does not.
    const words = new MutationObserver(fit);
    words.observe(head, { subtree: true, childList: true, characterData: true });
    return () => {
      observer.disconnect();
      words.disconnect();
    };
  }, [deck, signature, measured]);
  return fits;
}

type Mark = { harness?: string; tone?: number; icon: string };

/// A line's mark, as its line draws it (SubagentTray.tsx `stackMarks`), one per line here: each
/// command its own terminal, so each can be named and opened.
function markOf(item: TrayItem, chatHarness: string | undefined): Mark {
  if (item.kind === "agent")
    return { harness: item.agent.harness ?? chatHarness, tone: agentTone(item.agent.id), icon: SUBAGENT_FALLBACK };
  if (item.kind === "session")
    return { harness: item.session.harness, tone: agentTone(item.session.sessionId), icon: "agent.chat" };
  if (item.kind === "turn") return { icon: SILENT_TURN_ICON };
  return { icon: "terminal" };
}

export function HatHeadDeck({
  items,
  chatHarness,
  look,
  at = "lead",
  peeked,
  onPeek,
  onOpenItem,
}: {
  /// What runs, in the header's order (trayHeadOrder.ts, longest-running first).
  items: readonly TrayItem[];
  chatHarness: string | undefined;
  look: "strip" | "cards";
  /// Where it sits in the row: leading the words in the icon column, or after them (the one-line hat's
  /// `trail` arm, hatLine.experiment.ts).
  at?: "lead" | "trail";
  /// The key of the line the header names now (runningTray.ts `trayItemKey`), if one.
  peeked: string | undefined;
  onPeek: (key: string | undefined) => void;
  onOpenItem: (item: TrayItem) => void;
}) {
  const t = useT();
  const shown = items.slice(0, DECK_MARKS);
  const rest = items.length - shown.length;
  const wheel = useRef(0);
  const deckRef = useRef<HTMLSpanElement>(null);
  // After the one line's words (`trail`) the deck draws only what fits beside them, and "+N more" ends it
  // one gap after the last mark: no empty slots, so no floating gap before "+N more".
  const fits = useDeckFit(deckRef, `${shown.length}:${rest}:${at}:${look}`, at === "trail");
  // The `cards` look: the wheel over the deck thumbs from card to card, wrapping, from the one in front.
  const onWheel = (event: WheelEvent<HTMLSpanElement>) => {
    if (shown.length < 2) return;
    wheel.current += Math.abs(event.deltaY) >= Math.abs(event.deltaX) ? event.deltaY : event.deltaX;
    if (Math.abs(wheel.current) < WHEEL_STEP) return;
    const step = wheel.current > 0 ? 1 : -1;
    wheel.current = 0;
    const at = Math.max(
      0,
      shown.findIndex((item) => trayItemKey(item) === peeked),
    );
    const next = shown[(at + step + shown.length) % shown.length];
    if (next) onPeek(trayItemKey(next));
  };
  return (
    <span
      ref={deckRef}
      className="acpmux-hat-deck"
      data-fit={fits ? undefined : "off"}
      data-look={look}
      data-at={at}
      data-peeking={peeked !== undefined || undefined}
      aria-hidden="true"
      onPointerLeave={() => {
        wheel.current = 0;
        onPeek(undefined);
      }}
      onWheel={look === "cards" ? onWheel : undefined}
    >
      {shown.map((item, index) => {
        const key = trayItemKey(item);
        const mark = markOf(item, chatHarness);
        return (
          <span
            key={key}
            className="acpmux-hat-deck__mark"
            aria-hidden="true"
            data-deck-key={key}
            data-peeked={peeked === key || undefined}
            // The deck's order: the first card on top, each later one tucked under it.
            style={{ "--acpmux-deck-index": index, zIndex: shown.length - index } as CSSProperties}
            onPointerEnter={() => onPeek(key)}
            onClick={(event) => {
              event.stopPropagation();
              onOpenItem(item);
            }}
          >
            <span className="acpmux-hat-deck__face">
              {mark.harness !== undefined || mark.tone !== undefined ? (
                <AgentIdentity harness={mark.harness} tone={mark.tone} size={ROW_ICON} fallback={mark.icon} />
              ) : (
                <Icon name={mark.icon} size={ROW_ICON} row />
              )}
            </span>
          </span>
        );
      })}
      {rest > 0 && <span className="acpmux-summary-meta acpmux-hat-deck__rest">{t("tools.more", { n: rest })}</span>}
    </span>
  );
}
