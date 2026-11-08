// The "cmux Updated!" card's changes beside the sidebar (`#/surface/updated-notes`, the shipped
// look, updatedPreviewMode.ts): the native card host opens this page in the app's one hover card
// window, menu-wide, to the side of the sidebar, as the staged update card's highlights open. The
// card itself never grows.
//
// Lawrence 2026-11-07, on the list that grew up out of the bottom card over the sidebar's rows: "i
// dont like how it expands upwards, also it looks very bad". A calm header (what the app updated
// to, the full version, What's New), a hairline, then each change: its title whole, on as many
// lines as it needs, and a quiet detail under it (titles alone in the `beside-titles` look).
//
// Leo 2026-11-08: "the sections should be more obvious what's what ... distinguishing which row does
// what is unclear. therefore it is also unclear whether you can even scroll down and why you should
// ... if someone clicks it... maybe just bring them to the section in what's new aka bringing that tab
// up". The changes stand under What's New's own area headers (its glyph, name and count, in its
// order), each change is one pill, a count at the bottom says how many more are below while there
// are, and a click opens What's New at that change.
import { useEffect, useId, useRef, useState } from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import { useDecoration } from "../../theme/decorations";
import type { Strings } from "../shared/i18n";
import type { ReleaseNotes } from "./types";
import type { UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { AreaIcon } from "./SheetPage";
import { previewEntries, previewSections, type PreviewEntry } from "./updatedPreview";
import { parsePreviewMode, type UpdatedPreviewMode } from "./updatedPreviewMode";
import { CopyVersion } from "./UpdateSurfaces";

/** How the changes stand (gallery variants; `sections` ships): under their areas' headers with a gap
    between pills (`sections`), under the headers with hairlines between rows (`divided`), or one flat
    list (`flat`, the look before). */
export type NotesLook = "sections" | "divided" | "flat";

export function UpdatedNotes({
  data,
  span,
  strings,
  actions,
  mode,
  look = "sections",
}: {
  data: UpdateHighlights;
  /** The notes of every build the update spans, newest first; absent until they load. */
  span?: ReleaseNotes[];
  strings: Strings;
  actions: UpdateSurfaceActions;
  /** The card's look (gallery); undefined reads the theme's. */
  mode?: UpdatedPreviewMode;
  look?: NotesLook;
}) {
  const titleId = useId();
  const themed = parsePreviewMode(useDecoration("updated-card-preview"));
  const titlesOnly = (mode ?? themed) === "beside-titles";
  const [copied, setCopied] = useState(false);
  const scroller = useRef<HTMLElement | null>(null);
  const entries = previewEntries(data, span, strings.language);
  useEffect(() => (scroller.current ? installScrollEdges(scroller.current) : undefined), [entries.length]);
  const below = useRowsBelow(scroller, entries.length, look);
  const name = /^[^-]+-nightly\.\d+$/.test(data.version) ? strings.t("updates.card.nightly") : data.version;
  const titleKey = data.delivery === "background" ? "updates.card.updatedBehind" : "updates.card.updatedTo";
  const [before, after] = strings.format(titleKey, "\u0000").split("\u0000");
  return (
    <section
      className="wn-notes"
      data-titles={titlesOnly ? "" : undefined}
      aria-labelledby={titleId}
      ref={scroller}
      {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}
    >
      <header className="wn-notes-head">
        <div className="wn-notes-title" id={titleId}>
          {before}
          {name}
          {after}
        </div>
        <button type="button" className="wn-notes-whatsnew" onClick={() => actions.openChangelog()}>
          {strings.t("changelog.page.title")}
          <span aria-hidden="true"> ↗</span>
        </button>
        {/* The full version under the title, unless the title already says it (a release). */}
        {name !== data.version && (
          <div className="wn-notes-version">
            <CopyVersion version={data.version} strings={strings} onCopied={setCopied}>
              {data.version}
            </CopyVersion>
            <span aria-live="polite">{copied && ` · ${strings.t("updates.card.copied")}`}</span>
          </div>
        )}
      </header>
      {entries.length > 0 && (
        <ul className="wn-notes-list" data-look={look} aria-label={strings.t("changelog.page.title")}>
          {look === "flat"
            ? entries.map((entry) => (
                <NotesRow key={entry.id} entry={entry} titlesOnly={titlesOnly} actions={actions} />
              ))
            : previewSections(entries).map((section) => {
                const label = section.area
                  ? strings.t(`updates.area.${section.area}`)
                  : strings.t("changelog.page.otherArea");
                return (
                  <li key={section.area ?? "other"} className="wn-notes-section" data-area={section.area ?? "other"}>
                    <h3 className="wn-notes-area">
                      <span className="wn-notes-area-icon" aria-hidden="true">
                        <AreaIcon area={section.area} />
                      </span>
                      <span className="wn-notes-area-name">{label}</span>
                      <span className="wn-notes-area-count">{section.items.length}</span>
                    </h3>
                    <ul className="wn-notes-rows" aria-label={label}>
                      {section.items.map((entry) => (
                        <NotesRow key={entry.id} entry={entry} titlesOnly={titlesOnly} actions={actions} />
                      ))}
                    </ul>
                  </li>
                );
              })}
        </ul>
      )}
      {below > 0 && (
        <div className="wn-notes-more" aria-hidden="true">
          <svg viewBox="0 0 12 12" width="12" height="12">
            <path d="M3 4.5 6 7.5 9 4.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
          {strings.format("updates.card.more", String(below))}
        </div>
      )}
    </section>
  );
}

/** One change: its title and detail light together as one pill; a click opens What's New at it. */
function NotesRow({
  entry,
  titlesOnly,
  actions,
}: {
  entry: PreviewEntry;
  titlesOnly: boolean;
  actions: UpdateSurfaceActions;
}) {
  return (
    <li>
      <button
        type="button"
        className="wn-notes-row"
        onClick={() => actions.openChangelog({ area: entry.area, title: entry.title })}
      >
        <span className="wn-notes-row-title">{entry.title}</span>
        {!titlesOnly && entry.detail && <span className="wn-notes-row-detail">{entry.detail}</span>}
      </button>
    </li>
  );
}

/** How many rows stand past the scroller's bottom edge (more than half hidden), kept current as the
    list scrolls and as its rows or the popover change size. */
function useRowsBelow(scroller: { current: HTMLElement | null }, count: number, look: NotesLook): number {
  const [below, setBelow] = useState(0);
  useEffect(() => {
    const element = scroller.current;
    if (!element) return undefined;
    const recount = () => {
      const bottom = element.getBoundingClientRect().bottom;
      let hidden = 0;
      for (const row of element.querySelectorAll<HTMLElement>(".wn-notes-row")) {
        const rect = row.getBoundingClientRect();
        if (rect.top + rect.height / 2 > bottom) hidden++;
      }
      setBelow(hidden);
    };
    recount();
    element.addEventListener("scroll", recount, { passive: true });
    const resize = typeof ResizeObserver === "function" ? new ResizeObserver(recount) : undefined;
    resize?.observe(element);
    const list = element.querySelector(".wn-notes-list");
    if (list) resize?.observe(list);
    return () => {
      element.removeEventListener("scroll", recount);
      resize?.disconnect();
    };
  }, [scroller, count, look]);
  return below;
}
