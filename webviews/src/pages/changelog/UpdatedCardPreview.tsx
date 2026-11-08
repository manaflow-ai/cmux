// The Updated card's hover preview (updatedPreview.ts has the rows and the hover intent): a short,
// scrollable list of the update's changes inside the card's own glass, above the card's two lines.
// The card is anchored at its bottom (the sidebar's slot; surface.css), so opening it raises the
// glass's top edge over the rows, which stay where they are: no row slides, nothing below moves.
//
// Leo 2026-11-08: "the sections should be more obvious what's what ... distinguishing which row does
// what is unclear. therefore it is also unclear whether you can even scroll down and why you should.
// there should be expanded hover previews if somebody wants, and if someone clicks it... maybe just
// bring them to the section in what's new". The rows stand under their app areas as What's New groups
// them (a glyph, the name and a count, held at the list's top while its rows scroll under it); each
// row is one pill; a count under the list says how many more there are below; resting on a row shows
// its whole title and description in place; a click opens What's New at that row's area.
import { useEffect, useRef, useState, type Ref } from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import type { Strings } from "../shared/i18n";
import type { AreaKey } from "./areas";
import { AreaIcon } from "./SheetPage";
import { previewSections, type PreviewEntry } from "./updatedPreview";

/** The tallest the list gets, CSS px: about seven rows under their areas; the rest scrolls. */
export const PREVIEW_MAX_PX = 300;
/** How long the pointer rests on a row before the row shows its whole text: the hover-card dwell
    (PREVIEW_DWELL_MS), so running the pointer down the list expands nothing. */
export const ROW_PEEK_MS = 400;

/** Where a click on a row takes What's New: the row's area, and the row itself. */
export interface PreviewTarget {
  area?: AreaKey;
  title: string;
}

/** How the rows stand (gallery variants; `sections` ships): under their areas' headers (`sections`),
    under headers with hairlines between rows (`divided`), or one flat list (`flat`, the look before). */
export type PreviewLook = "sections" | "divided" | "flat";

export function UpdatedCardPreview({
  entries,
  shown,
  strings,
  listRef,
  onOpen,
  look = "sections",
  peek,
}: {
  entries: PreviewEntry[];
  /** The preview is open: its rows take the keyboard and the screen reader. */
  shown: boolean;
  strings: Strings;
  listRef: Ref<HTMLUListElement>;
  /** A row opens What's New at its area. */
  onOpen: (target?: PreviewTarget) => void;
  look?: PreviewLook;
  /** A row shown expanded from the start (gallery stills); undefined: the pointer decides. */
  peek?: string;
}) {
  const scroller = useRef<HTMLUListElement | null>(null);
  const [below, setBelow] = useState(0);
  const [resting, setResting] = useState<string | undefined>(undefined);
  const peekTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => {
    const element = scroller.current;
    if (!element) return undefined;
    const stop = installScrollEdges(element);
    // The rows past the list's bottom edge: the count under the list says there is more, and how much.
    const count = () => {
      const bottom = element.scrollTop + element.clientHeight - 1;
      let hidden = 0;
      for (const row of element.querySelectorAll<HTMLElement>(".wn-preview-row"))
        if (row.offsetTop + row.offsetHeight / 2 > bottom) hidden++;
      setBelow(hidden);
    };
    count();
    element.addEventListener("scroll", count, { passive: true });
    return () => {
      stop();
      element.removeEventListener("scroll", count);
    };
  }, [entries, shown, look]);
  useEffect(() => () => clearTimeout(peekTimer.current), []);
  // A closed preview forgets the row it expanded: it opens with every row on one line.
  useEffect(() => {
    if (!shown) setResting(undefined);
  }, [shown]);
  const setList = (element: HTMLUListElement | null) => {
    scroller.current = element;
    if (typeof listRef === "function") listRef(element);
    else if (listRef) listRef.current = element;
  };
  const rest = (id: string | undefined) => {
    clearTimeout(peekTimer.current);
    if (id === undefined) return setResting(undefined);
    peekTimer.current = setTimeout(() => setResting(id), ROW_PEEK_MS);
  };
  const expanded = peek ?? resting;
  const row = (entry: PreviewEntry) => (
    <li key={entry.id}>
      <button
        type="button"
        className="wn-preview-row"
        tabIndex={shown ? 0 : -1}
        data-peek={expanded === entry.id ? "" : undefined}
        onPointerEnter={() => rest(entry.id)}
        onPointerLeave={() => rest(undefined)}
        onFocus={() => setResting(entry.id)}
        onClick={() => onOpen({ area: entry.area, title: entry.title })}
      >
        <span className="wn-preview-title">{entry.title}</span>
        {entry.detail && <span className="wn-preview-detail">{entry.detail}</span>}
      </button>
    </li>
  );
  const sections = look === "flat" ? [{ area: undefined, items: entries }] : previewSections(entries);
  return (
    <div className="wn-preview" aria-hidden={!shown} data-look={look}>
      <ul
        className="wn-preview-list"
        ref={setList}
        aria-label={strings.t("changelog.page.title")}
        {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}
      >
        {look === "flat"
          ? entries.map(row)
          : sections.map((section) => {
              const label = section.area
                ? strings.t(`updates.area.${section.area}`)
                : strings.t("changelog.page.otherArea");
              return (
                <li key={section.area ?? "other"} className="wn-preview-section" data-area={section.area ?? "other"}>
                  <h3 className="wn-preview-area">
                    <span className="wn-preview-area-icon" aria-hidden="true">
                      <AreaIcon area={section.area} />
                    </span>
                    <span className="wn-preview-area-name">{label}</span>
                    <span className="wn-preview-area-count">{section.items.length}</span>
                  </h3>
                  <ul className="wn-preview-rows" aria-label={label}>
                    {section.items.map(row)}
                  </ul>
                </li>
              );
            })}
      </ul>
      {below > 0 && (
        <div className="wn-preview-more" aria-hidden="true">
          <svg viewBox="0 0 12 12" width="12" height="12">
            <path d="M3 4.5 6 7.5 9 4.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
          {strings.format("updates.card.more", String(below))}
        </div>
      )}
    </div>
  );
}
