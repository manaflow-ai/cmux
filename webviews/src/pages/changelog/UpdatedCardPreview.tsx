// The Updated card's hover preview (updatedPreview.ts has the rows and the hover intent): a short,
// scrollable list of the update's changes inside the card's own glass, above the card's two lines.
// The card is anchored at its bottom (the sidebar's slot; surface.css), so opening it raises the
// glass's top edge over the rows, which stay where they are: no row slides, nothing below moves.
import { useEffect, useRef, type Ref } from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import type { Strings } from "../shared/i18n";
import type { PreviewEntry } from "./updatedPreview";

/** The tallest the list gets, CSS px: about nine rows; the rest scrolls. */
export const PREVIEW_MAX_PX = 264;

export function UpdatedCardPreview({
  entries,
  shown,
  strings,
  listRef,
  onOpen,
}: {
  entries: PreviewEntry[];
  /** The preview is open: its rows take the keyboard and the screen reader. */
  shown: boolean;
  strings: Strings;
  listRef: Ref<HTMLUListElement>;
  /** A row opens the full What's New page. */
  onOpen: () => void;
}) {
  const scroller = useRef<HTMLUListElement | null>(null);
  useEffect(() => (scroller.current ? installScrollEdges(scroller.current) : undefined), [entries]);
  const setList = (element: HTMLUListElement | null) => {
    scroller.current = element;
    if (typeof listRef === "function") listRef(element);
    else if (listRef) listRef.current = element;
  };
  return (
    <div className="wn-preview" aria-hidden={!shown}>
      <ul
        className="wn-preview-list"
        ref={setList}
        aria-label={strings.t("changelog.page.title")}
        {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}
      >
        {entries.map((entry) => (
          <li key={entry.id}>
            <button type="button" className="wn-preview-row" tabIndex={shown ? 0 : -1} onClick={onOpen}>
              <span className="wn-preview-title">{entry.title}</span>
              {entry.detail && <span className="wn-preview-detail">{entry.detail}</span>}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
