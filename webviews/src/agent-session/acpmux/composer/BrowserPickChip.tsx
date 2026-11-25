// A browser pick's chip (browserPickModel.ts): the pick's number in its own badge, the same number
// as its pin on the page, then the person's comment over the element and page it is about. One chip
// per pick (its crop rides inside it), so several picks in a row stay one tidy row of chips. A click,
// Return or Space opens the whole card in place, as an inspector pick's does (UIPickChip.tsx).
import type { ReactNode } from "react";
import { useT } from "../i18n";
import { browserPickRows } from "./browserPickModel";
import { ContentChip } from "./ContentChip";
import type { ChipHost } from "./contentChipModel";
import { LABEL_SEPARATOR } from "./pastedTextChipModel";
import { UI_PICK_COLLAPSE } from "./uiPickModel";

export function BrowserPickChip({
  host,
  name,
  text,
  remove,
  open,
  onOpenChange,
}: {
  host: ChipHost;
  /// The attachment's name ("1 · Make this blue").
  name: string;
  /// The pick's whole card.
  text: string;
  /// The host's × (shown on hover or focus); none in a sent message.
  remove?: ReactNode;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}) {
  const t = useT();
  const { number, title, caption } = browserPickRows(t, name, text);
  const read = [
    ...(number === undefined ? [] : [String(number)]),
    ...[...title, ...caption].map((part) => part.text),
  ].join(LABEL_SEPARATOR);
  return (
    <ContentChip
      host={host}
      kind="ui"
      design={`browser-pick ${UI_PICK_COLLAPSE}`}
      opening={{ kind: "panel", collapse: UI_PICK_COLLAPSE }}
      icon={
        <span className="acpmux-browser-pick-number" aria-hidden="true">
          {number ?? "•"}
        </span>
      }
      title={title}
      label={caption}
      accessibleName={read}
      {...(remove ? { remove } : {})}
      {...(open === undefined ? {} : { open })}
      {...(onOpenChange ? { onOpenChange } : {})}
      text={text}
    />
  );
}
