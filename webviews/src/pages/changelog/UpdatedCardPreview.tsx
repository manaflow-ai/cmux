// The Updated card's hover preview (updatedPreview.ts has the rows and the hover intent): What's New,
// the last line of the card's header (the card's own lines show its title and, open, the full
// version), and a short, scrollable list of the update's changes, inside the card's own glass.
//
// Lawrence 2026-11-07, "this ui is very bad": every line was cut with an ellipsis, the version never
// showed ("Updated to ..."), What's New floated after the cut title and the last row was dimmed by
// the list's scroll fade. The header now reads whole (the title, the full version, What's New on
// its own line), each change's title wraps onto a second line instead of being cut, and the list
// marks more rows with its scrollbar, not by fading a row.
import { useEffect, useRef, type Ref } from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import type { Strings } from "../shared/i18n";
import type { AreaKey } from "./areas";
import type { PreviewEntry } from "./updatedPreview";

/** The tallest the preview gets, CSS px: its header line and about seven rows; the rest scrolls. */
export const PREVIEW_MAX_PX = 300;

/**
 * How the open preview is laid out (gallery variants; `header` ships).
 * - `header`: the card's header leads the open panel (its title line, then the version and What's
 *   New), the changes under it, each title on up to two lines with its detail.
 * - `header-bottom`: the same parts with the header kept under the pointer at the card's resting
 *   edge, the changes beyond it (the order before).
 * - `titles`: the header leads, and the changes are their titles alone, on up to three lines.
 */
/** Where a click on a row takes What's New: the row's area, and the row itself. */
export interface PreviewTarget {
  area?: AreaKey;
  title: string;
}

export type PreviewLayout = "header" | "header-bottom" | "titles";

export function UpdatedCardPreview({
  entries,
  shown,
  strings,
  bodyRef,
  onOpen,
}: {
  entries: PreviewEntry[];
  /** The preview is open: its rows take the keyboard and the screen reader. */
  shown: boolean;
  strings: Strings;
  /** The preview's content (measured for its height). */
  bodyRef: Ref<HTMLDivElement>;
  /** What's New opens the full What's New page; a row opens it at its change. */
  onOpen: (target?: PreviewTarget) => void;
}) {
  const scroller = useRef<HTMLUListElement | null>(null);
  useEffect(() => (scroller.current ? installScrollEdges(scroller.current) : undefined), [entries]);
  const tab = shown ? 0 : -1;
  return (
    <div className="wn-preview" aria-hidden={!shown}>
      <div className="wn-preview-body" ref={bodyRef}>
        <div className="wn-preview-head">
          <button type="button" className="wn-preview-whatsnew" tabIndex={tab} onClick={() => onOpen()}>
            {strings.t("changelog.page.title")}
            <span aria-hidden="true"> ↗</span>
          </button>
        </div>
        <ul
          className="wn-preview-list"
          ref={scroller}
          aria-label={strings.t("changelog.page.title")}
          {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}
        >
          {entries.map((entry) => (
            <li key={entry.id}>
              <button
                type="button"
                className="wn-preview-row"
                tabIndex={tab}
                onClick={() => onOpen({ area: entry.area, title: entry.title })}
              >
                <span className="wn-preview-title">{entry.title}</span>
                {entry.detail && <span className="wn-preview-detail">{entry.detail}</span>}
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
