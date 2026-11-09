// An inspector pick's chip (uiPickModel.ts): the element the person picked and a snippet of its
// text (`span · "the Cloud version-check…"`) over its kind and selector, with the pointer glyph.
// A click, Return or Space opens the whole report in place under the face, in a bounded scroller;
// the Collapse button folds it back, and so does Escape. In the composer's strip, placed in the
// prompt's text, and in a sent message, where the report went to the agent whole.
// Leo, 2026-11-08: "clicking it should be able to show the raw/full thing... idk how possible it'd be
// to also be able to have a well-designed button to click to re-collapse it too."
import { type ReactNode, useContext } from "react";
import { PointerClick } from "../conversation/icons";
import { useT } from "../i18n";
import { ContentChip } from "./ContentChip";
import type { ChipHost } from "./contentChipModel";
import { LABEL_SEPARATOR } from "./pastedTextChipModel";
import { UIPickDesignContext, uiPickRows } from "./uiPickModel";

export function UIPickChip({
  host,
  name,
  text,
  remove,
  open,
  onOpenChange,
}: {
  host: ChipHost;
  /// The attachment's name ("UI: span").
  name: string;
  /// The inspector's whole report.
  text: string;
  /// The host's × (shown on hover or focus); none in a sent message.
  remove?: ReactNode;
  /// Kept by the host when given (a sent message's disclosure: SentUIPick.tsx SentUIPickChip).
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}) {
  const t = useT();
  const { label: form, collapse } = useContext(UIPickDesignContext);
  const { title, caption } = uiPickRows(t, name, text, form);
  const read = [...title, ...caption].map((part) => part.text).join(LABEL_SEPARATOR);
  return (
    <ContentChip
      host={host}
      kind="ui"
      design={`${form} ${collapse}`}
      opening={{ kind: "panel", collapse }}
      icon={<PointerClick size={16} />}
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
