// A lost link, as a small mark in the page's corner instead of a line in its flow. Leo, 2026-11-21:
// "typically for these connection indicators you can just put a small unobtrusive thing somewhere
// without needing to block any content ... a symbol or short thing, not a sentence. stop layout
// shifting". The mark is fixed to the viewport, so it takes no room: nothing below it moves when it
// comes or goes. Its sentence is the tooltip and the accessible name. The caller still holds it
// with `useConnectionQuiet` (ui/lasting.ts): a link that heals in seconds shows nothing.
import { cx } from "./cx";
import "./connectionChip.css";

export function ConnectionChip({
  text,
  className,
  dataAttrs,
}: {
  text: string;
  className?: string;
  /** Extra `data-*` attributes (a page's own hook for its tests and styles), keyed by full name. */
  dataAttrs?: Record<`data-${string}`, string>;
}) {
  return (
    <output
      className={cx("ui-connection-chip", className)}
      data-connection-chip=""
      {...dataAttrs}
      // tooltip-allow: the mark has no words on it; its tooltip is the one line that says what is lost
      title={text}
    >
      <span className="ui-connection-chip__dot" aria-hidden="true" />
      <span className="visually-hidden">{text}</span>
    </output>
  );
}
