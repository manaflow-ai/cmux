import { useLayoutEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { useHoverIntent } from "../../../ui/hoverIntent";

/** A chat's rolling summary as the daemon keeps it (acpmux `rollingSummary`, hub/rolling_summary.rs). */
export type ChatSummary = { text: string; next?: string | null };

/** How the summary shows: its whole line, or the chip that opens it. */
export type ChatSummaryFit = "line" | "chip";

/**
 * Where the chat stands and its next action (David Beyer, 2026-11-20: rolling summaries of every chat
 * with a next action for each). The daemon writes it after each turn a person started.
 *
 * It is never a line cut off mid-word (Leo, 2026-11-23: "unwilling to accept a banner at the top of a
 * single fucking line that gets cut off"). Beside the chat's name it shows whole while the room left
 * after the name holds all of it; with less room it folds to one square chip with the summary's glyph.
 * Hovering or clicking either opens the whole summary and next action, wrapped, in a card.
 *
 * `chip`: always the chip. The tab-row header uses it: there the chip is one more square tool, so the
 * tools' width never depends on the summary's text, and the App's tab row never drops them to a second
 * row under the tabs.
 */
export function ChatSummaryLine({ summary, chip }: { summary?: ChatSummary | null; chip?: boolean }) {
  const t = useT();
  const text = summary?.text?.trim();
  const next = summary?.next?.trim() || undefined;
  const slot = useRef<HTMLSpanElement | null>(null);
  const measure = useRef<HTMLSpanElement | null>(null);
  const fit = useSummaryFit(slot, measure, !!text && !chip, `${text ?? ""}\n${next ?? ""}`);
  const [open, setOpen] = useState(false);
  const [anchor, setAnchor] = useState<HTMLElement | null>(null);
  const anchorRef = useRef<HTMLElement | null>(null);
  const trigger = usePopoverTrigger(open, setOpen);
  const hover = useHoverIntent<true>({ delay: 350 });
  if (!text) return null;
  const full = next ? `${text}\n${t("header.summaryNext", { next })}` : text;
  const shown: ChatSummaryFit = chip ? "chip" : fit;
  const bind = (element: HTMLElement | null) => {
    anchorRef.current = element;
    setAnchor(element);
  };
  const hoverHandlers = {
    onPointerEnter: () => hover.hover(true),
    onPointerLeave: () => hover.hover(null),
  };
  const parts = (
    <>
      <span className="acpmux-chat-summary__text">{text}</span>
      {next && (
        <>
          <span className="acpmux-chat-summary__arrow" aria-hidden="true">
            →
          </span>
          <span className="acpmux-chat-summary__next">{next}</span>
        </>
      )}
    </>
  );
  return (
    <span
      ref={slot}
      className={chip ? "acpmux-chat-summary-slot acpmux-chat-summary-slot--tool" : "acpmux-chat-summary-slot"}
      data-chat-summary={shown}
    >
      {!chip && (
        <span ref={measure} className="acpmux-chat-summary acpmux-chat-summary--measure" aria-hidden="true">
          {parts}
        </span>
      )}
      {shown === "chip" ? (
        <button
          ref={bind}
          type="button"
          className="acpmux-header-tool acpmux-chat-summary-chip"
          aria-label={full}
          {...trigger}
          {...hoverHandlers}
        >
          <Icon name="transcript.summary" size={14} className="acpmux-header-glyph" />
        </button>
      ) : (
        <button
          ref={bind}
          type="button"
          className="acpmux-chat-summary"
          aria-label={full}
          {...trigger}
          {...hoverHandlers}
        >
          {parts}
        </button>
      )}
      <Popover
        id={trigger["aria-controls"]}
        open={open || hover.shown === true}
        onOpenChange={(value) => {
          if (!value) {
            setOpen(false);
            hover.dismiss();
          }
        }}
        anchor={anchor}
        label={t("summary.title")}
        className="acpmux-chat-summary-card"
        side="bottom"
        flip="shift"
        initialFocus={false}
        finalFocus={open ? anchorRef : false}
      >
        <div className="acpmux-chat-summary-card__body" {...hoverHandlers}>
          <p className="acpmux-chat-summary-card__text">{text}</p>
          {next && <p className="acpmux-chat-summary-card__next">{t("header.summaryNext", { next })}</p>}
        </div>
      </Popover>
    </span>
  );
}

/// "line" while the slot (the room the title leaves; flex 1 1 0, so its width never depends on what it shows)
/// holds the whole line at its natural width, else "chip". Event-driven: a ResizeObserver on the slot and the
/// measure. No flip-flop: neither width depends on the answer.
function useSummaryFit(
  slot: React.RefObject<HTMLElement | null>,
  measure: React.RefObject<HTMLElement | null>,
  enabled: boolean,
  key: string,
): ChatSummaryFit {
  const [fit, setFit] = useState<ChatSummaryFit>("chip");
  useLayoutEffect(() => {
    const room = slot.current;
    const line = measure.current;
    if (!enabled || !room || !line) return;
    const read = () => {
      const need = Math.ceil(line.getBoundingClientRect().width);
      const have = Math.floor(room.getBoundingClientRect().width);
      setFit(need > 0 && need <= have ? "line" : "chip");
    };
    read();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(read);
    observer.observe(room);
    observer.observe(line);
    return () => observer.disconnect();
  }, [slot, measure, enabled, key]);
  return fit;
}
