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
//
// Leo 2026-11-14, on the popover's blobby cloud, its icon-less Other and rows like "Redesign Cloud
// connection gates with human targets": "theese are kinda crappy looking icons and stuff", then, with
// Claude Code's What's New sheet: "here's how claude code does some of their what's new for example".
// The `release` look ships: the changes under New, Improved and Fixed labels in small capitals, one
// plain sentence per bullet (readableChange.ts plainChange), the version a quiet mono chip, and what
// no person sees folded into one "Maintenance and fixes" line. The area looks draw each area's symbol
// from the app's own set (SheetPage.tsx AREA_SYMBOLS) on one grid column with its name and count.
//
// A long update's list (`release`, `sections`, `divided`, `flat`) draws only the rows in or near the
// scroller, each group's rows a TanStack list of its own (WindowedRows), and redraws a row only when
// its own change does; the count of rows below reads the lists' sizes, not every row's box.
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ComponentProps,
} from "react";
import { measureElement as measureRow, useVirtualizer, type Virtualizer } from "@tanstack/react-virtual";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import { useDecoration } from "../../theme/decorations";
import type { Strings } from "../shared/i18n";
import type { ReleaseNotes } from "./types";
import type { UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { Icon } from "../settings/icons";
import { AreaIcon } from "./SheetPage";
import type { WhatsNewCategory } from "./types";
import { plainEntries, previewEntries, previewSections, type PreviewEntry } from "./updatedPreview";
import { ChipNotes, DigestNotes, HeadlineNotes, LedgerNotes, NotesRow } from "./UpdatedNotesLooks";
import { parsePreviewMode, type UpdatedPreviewMode } from "./updatedPreviewMode";
import { CopyVersion } from "./UpdateSurfaces";
import { GoBack, GoBackHeaderLink, type GoBackLook } from "./GoBack";

/** How the changes stand (`sections` ships): under their areas' headers with a gap between pills
    (`sections`), under the headers with hairlines between rows (`divided`, gallery), one flat list
    (`flat`, the look before, gallery), or one of the Debug looks (UpdatedNotesLooks.tsx: `digest`,
    `chips`, `headline`, `ledger`; Debug Settings `sidebar.updatedCard.notesLook`). */
export type NotesLook = "release" | "sections" | "divided" | "flat" | "digest" | "chips" | "headline" | "ledger";

const LOOKS: readonly NotesLook[] = ["release", "sections", "divided", "flat", "digest", "chips", "headline", "ledger"];

/** How an area look's headers draw their symbol: in the label's own quiet color (`mono`), or in the
    theme's accent as What's New's page does (`accent`, gallery). */
export type NotesHead = "mono" | "accent";

/** The look the theme's `updated-notes-look` slot names; `release` without one or for a name it does not know. */
export function parseNotesLook(value: string | null | undefined): NotesLook {
  return LOOKS.find((look) => look === value) ?? "release";
}

/** The kinds the `release` look heads its changes with, in this order. */
const KINDS: readonly WhatsNewCategory[] = ["new", "improved", "fixed", "security"];

export function UpdatedNotes({
  data,
  span,
  strings,
  actions,
  mode,
  look: lookProp,
  goBackLook = "footer",
  goBackFixture,
  head = "mono",
}: {
  data: UpdateHighlights;
  /** The notes of every build the update spans, newest first; absent until they load. */
  span?: ReleaseNotes[];
  strings: Strings;
  actions: UpdateSurfaceActions;
  /** The card's look (gallery); undefined reads the theme's. */
  mode?: UpdatedPreviewMode;
  /** How the changes stand (gallery); undefined reads the theme's. */
  look?: NotesLook;
  /** Where the way back to an earlier build stands (GoBack.tsx; gallery); `footer` ships. */
  goBackLook?: GoBackLook;
  /** The way back's props held for a gallery still. */
  goBackFixture?: Pick<Parameters<typeof GoBack>[0], "builds" | "open" | "state">;
  /** How an area look's headers draw their symbol (gallery). */
  head?: NotesHead;
}) {
  const themedLook = parseNotesLook(useDecoration("updated-notes-look"));
  const look = lookProp ?? themedLook;
  const titleId = useId();
  const themed = parsePreviewMode(useDecoration("updated-card-preview"));
  const titlesOnly = (mode ?? themed) === "beside-titles";
  const [copied, setCopied] = useState(false);
  const scroller = useRef<HTMLElement | null>(null);
  const { entries, maintenance } = useMemo(
    () => plainEntries(previewEntries(data, span, strings.language), strings.language),
    [data, span, strings.language],
  );
  const sections = useMemo(() => previewSections(entries), [entries]);
  useEffect(() => (scroller.current ? installScrollEdges(scroller.current) : undefined), [entries.length]);
  const counters = useMemo<RowCounters>(() => new Map(), []);
  const rows = useMemo<RowsWindow>(
    () => ({ windowed: entries.length > WINDOW_ROWS, counters, titlesOnly, actions }),
    [entries.length, counters, titlesOnly, actions],
  );
  const below = useRowsBelow(scroller, counters, entries.length, look);
  const name = /^[^-]+-nightly\.\d+$/.test(data.version) ? strings.t("updates.card.nightly") : data.version;
  const titleKey = data.delivery === "background" ? "updates.card.updatedBehind" : "updates.card.updatedTo";
  const [before, after] = strings.format(titleKey, "\u0000").split("\u0000");
  return (
    <section
      className="wn-notes"
      data-look={look}
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
        <span className="wn-notes-links">
          {goBackLook === "header" && <GoBackHeaderLink goBack={data.goBack} strings={strings} actions={actions} />}
          <button type="button" className="wn-notes-whatsnew" onClick={() => actions.openChangelog()}>
            {strings.t("changelog.page.title")}
          </button>
        </span>
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
      {(entries.length > 0 || maintenance > 0) && look === "release" && (
        <ReleaseList entries={entries} maintenance={maintenance} strings={strings} actions={actions} rows={rows} />
      )}
      {entries.length > 0 && look === "digest" && (
        <DigestNotes entries={entries} titlesOnly={titlesOnly} strings={strings} actions={actions} />
      )}
      {entries.length > 0 && look === "chips" && (
        <ChipNotes entries={entries} titlesOnly={titlesOnly} strings={strings} actions={actions} />
      )}
      {entries.length > 0 && look === "headline" && (
        <HeadlineNotes entries={entries} titlesOnly={titlesOnly} strings={strings} actions={actions} />
      )}
      {entries.length > 0 && look === "ledger" && <LedgerNotes entries={entries} strings={strings} actions={actions} />}
      {entries.length > 0 && look === "flat" && (
        <WindowedRows
          group="flat"
          entries={entries}
          rows={rows}
          className="wn-notes-list"
          data-look={look}
          data-head={head}
          aria-label={strings.t("changelog.page.title")}
        />
      )}
      {entries.length > 0 && (look === "sections" || look === "divided") && (
        <ul className="wn-notes-list" data-look={look} data-head={head} aria-label={strings.t("changelog.page.title")}>
          {sections.map((section) => {
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
                <WindowedRows
                  group={section.area ?? "other"}
                  entries={section.items}
                  rows={rows}
                  className="wn-notes-rows"
                  aria-label={label}
                />
              </li>
            );
          })}
          {maintenance > 0 && (
            <li className="wn-notes-section" data-area="maintenance">
              <button
                type="button"
                className="wn-notes-area wn-notes-maintenance"
                onClick={() => actions.openChangelog()}
              >
                <span className="wn-notes-area-icon" aria-hidden="true">
                  <Icon name="hammer" className="area-symbol" />
                </span>
                <span className="wn-notes-area-name">{strings.t("changelog.page.maintenance")}</span>
                <span className="wn-notes-area-count">{maintenance}</span>
              </button>
            </li>
          )}
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
      {goBackLook !== "header" && (
        <GoBack
          goBack={data.goBack}
          running={data.goBackRunning === true}
          strings={strings}
          actions={actions}
          look={goBackLook}
          {...goBackFixture}
        />
      )}
    </section>
  );
}

/** `release`: the changes under New, Improved and Fixed in small capitals, one bullet each, then how
    many changes no person sees, as one quiet line (Leo's Claude Code reference, 2026-11-14). */
function ReleaseList({
  entries,
  maintenance,
  strings,
  actions,
  rows,
}: {
  entries: PreviewEntry[];
  maintenance: number;
  strings: Strings;
  actions: UpdateSurfaceActions;
  rows: RowsWindow;
}) {
  const kinds = useMemo(
    () =>
      KINDS.map((kind) => ({
        kind,
        items: entries.filter((entry) => (entry.category ?? "improved") === kind),
      })).filter((group) => group.items.length > 0),
    [entries],
  );
  return (
    <div className="wn-notes-list" data-look="release" aria-label={strings.t("changelog.page.title")}>
      {kinds.map(({ kind, items }) => {
        const label = strings.t(`changelog.group.${kind}`);
        return (
          <section key={kind} className="wn-notes-kind" data-kind={kind} aria-label={label}>
            <h3 className="wn-notes-kind-label">{label}</h3>
            <WindowedRows group={kind} entries={items} rows={rows} className="wn-notes-rows" />
          </section>
        );
      })}
      {maintenance > 0 && (
        <button type="button" className="wn-notes-maintenance-line" onClick={() => actions.openChangelog()}>
          {strings.t("changelog.page.maintenance")}
          <span className="wn-notes-area-count">{maintenance}</span>
        </button>
      )}
    </div>
  );
}

/** A list longer than this draws only the rows in or near the scroller; a shorter one draws all. */
export const WINDOW_ROWS = 60;

/** How many rows past each edge of the scroller a long list keeps drawn: about a popover's height. */
const ROW_OVERSCAN = 12;

/** Each windowed group's count of its rows past a scroll offset (rowsPast), by group. */
type RowCounters = Map<string, (bottom: number) => number>;

/** What every group of a list shares: whether it windows, where its groups report their rows below,
    and how a row draws. */
interface RowsWindow {
  windowed: boolean;
  counters: RowCounters;
  titlesOnly: boolean;
  actions: UpdateSurfaceActions;
}

/** A row redrawn only when its own change does: a list's entries are made anew each time the notes
    are read, so the same fields, not the same object, are the same row. */
const NotesItem = memo(
  NotesRow,
  (a, b) =>
    a.titlesOnly === b.titlesOnly &&
    a.actions === b.actions &&
    a.index === b.index &&
    a.measure === b.measure &&
    (a.entry === b.entry ||
      (a.entry.id === b.entry.id &&
        a.entry.title === b.entry.title &&
        a.entry.detail === b.entry.detail &&
        a.entry.category === b.entry.category &&
        a.entry.area === b.entry.area &&
        a.entry.target === b.entry.target)),
);

/** One group's rows (`group` names it among the list's), a TanStack list over the card's scroller
    from where the group starts in it: in a long list the rows near the scroller (none while the whole
    group is a screen or more away), the rest held as padding, so the scroller is as tall as with
    every row; in a short one every row. Either way each row is measured, so the group counts its
    rows below an offset without reading a row's box. */
function WindowedRows({
  group,
  entries,
  rows,
  ...list
}: { group: string; entries: PreviewEntry[]; rows: RowsWindow } & ComponentProps<"ul">) {
  const { windowed, counters } = rows;
  const ul = useRef<HTMLUListElement>(null);
  // The card's scroller, found from the list: its ref is set after this group's effects run.
  const scroller = useCallback(() => ul.current?.closest<HTMLElement>(".wn-notes") ?? null, []);
  // Where the group starts in the scroller's content, and the gap between its rows (the `sections`
  // look's pills stand apart). A group above it growing moves it, so the whole list is watched.
  const [place, setPlace] = useState({ top: 0, gap: 0 });
  useLayoutEffect(() => {
    const element = ul.current;
    const box = scroller();
    if (!element || !box) return undefined;
    const read = () => {
      const top = Math.round(element.getBoundingClientRect().top - box.getBoundingClientRect().top + box.scrollTop);
      const gap = Number.parseFloat(element.ownerDocument.defaultView?.getComputedStyle(element).rowGap ?? "") || 0;
      setPlace((was) => (was.top === top && was.gap === gap ? was : { top, gap }));
    };
    read();
    const resize = typeof ResizeObserver === "function" ? new ResizeObserver(read) : undefined;
    resize?.observe(element.closest(".wn-notes-list") ?? element);
    return () => resize?.disconnect();
  }, [scroller]);
  const getItemKey = useCallback((index: number) => entries[index]!.id, [entries]);
  // A row not drawn yet is guessed as tall as the first row measured, so drawing one as the list
  // scrolls does not move every row under it (TanStack places each again when a size differs from
  // its guess).
  const measured = useMemo<{ size?: number }>(() => ({}), []);
  const estimateSize = useCallback(() => measured.size ?? (rows.titlesOnly ? 32 : 52), [measured, rows.titlesOnly]);
  const measureElement = useCallback(
    (element: Element, entry: ResizeObserverEntry | undefined, instance: Virtualizer<HTMLElement, Element>) => {
      const size = measureRow(element, entry, instance);
      if (measured.size === undefined && size > 0) measured.size = size;
      return size;
    },
    [measured],
  );
  const virtualizer = useVirtualizer<HTMLElement, Element>({
    count: entries.length,
    getScrollElement: scroller,
    estimateSize,
    getItemKey,
    measureElement,
    gap: place.gap,
    scrollMargin: place.top,
    overscan: ROW_OVERSCAN,
    // The first frame draws a popover's worth of rows before the scroller is measured.
    initialRect: { width: 320, height: 640 },
  });
  useLayoutEffect(() => {
    counters.set(group, (bottom) => rowsPast(virtualizer, bottom));
    return () => {
      counters.delete(group);
    };
  }, [counters, group, virtualizer]);
  // Whether any of the group is within a screen of the scroller's view, checked on each scroll (the
  // virtualizer redraws only as its range moves, which it does not while the group is out of view).
  const subscribe = useCallback(
    (changed: () => void) => {
      const box = scroller();
      box?.addEventListener("scroll", changed, { passive: true });
      return () => box?.removeEventListener("scroll", changed);
    },
    [scroller],
  );
  const near = useSyncExternalStore(subscribe, () => {
    if (!windowed) return true;
    const offset = virtualizer.scrollOffset ?? 0;
    const height = virtualizer.scrollRect?.height ?? 0;
    return place.top < offset + 2 * height && place.top + virtualizer.getTotalSize() > offset - height;
  });
  const drawn = windowed ? (near ? virtualizer.getVirtualItems() : []) : undefined;
  const first = drawn?.[0];
  const last = drawn?.[drawn.length - 1];
  const padding = !drawn
    ? undefined
    : first && last
      ? { paddingTop: first.start - place.top, paddingBottom: virtualizer.getTotalSize() - (last.end - place.top) }
      : { paddingTop: virtualizer.getTotalSize() };
  return (
    <ul {...list} ref={ul} style={padding}>
      {(drawn ?? entries.map((_, index) => ({ index }))).map(({ index }) => (
        <NotesItem
          key={entries[index]!.id}
          index={index}
          measure={virtualizer.measureElement}
          entry={entries[index]!}
          titlesOnly={rows.titlesOnly}
          actions={rows.actions}
        />
      ))}
    </ul>
  );
}

/** How many of a group's rows stand past `bottom` (more than half below it), by a binary search of
    its measured rows. */
function rowsPast(virtualizer: Virtualizer<HTMLElement, Element>, bottom: number): number {
  // Asking for the row at `bottom` brings the measurements up to date.
  if (!virtualizer.getVirtualItemForOffset(bottom)) return 0;
  const rows = virtualizer.measurementsCache;
  let low = 0;
  let high = rows.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    const row = rows[middle]!;
    if (row.start + row.size / 2 > bottom) high = middle;
    else low = middle + 1;
  }
  return rows.length - low;
}

/** How many rows stand past the scroller's bottom edge (more than half hidden), kept current, once
    a frame, as the list scrolls and as its rows or the popover change size. The windowed groups
    count theirs from their sizes; the other looks' rows are read from the page by a binary search,
    rows standing in order down the list. */
function useRowsBelow(
  scroller: { current: HTMLElement | null },
  counters: RowCounters,
  count: number,
  look: NotesLook,
): number {
  const [below, setBelow] = useState(0);
  useEffect(() => {
    const element = scroller.current;
    if (!element) return undefined;
    const view = element.ownerDocument.defaultView;
    let rows: HTMLElement[] = [];
    let frame = 0;
    const recount = () => {
      frame = 0;
      if (counters.size > 0) {
        const bottom = element.scrollTop + element.clientHeight;
        let hidden = 0;
        for (const rowsBelow of counters.values()) hidden += rowsBelow(bottom);
        setBelow(hidden);
        return;
      }
      const bottom = element.getBoundingClientRect().bottom;
      let low = 0;
      let high = rows.length;
      while (low < high) {
        const middle = (low + high) >> 1;
        const rect = rows[middle]!.getBoundingClientRect();
        if (rect.top + rect.height / 2 > bottom) high = middle;
        else low = middle + 1;
      }
      setBelow(rows.length - low);
    };
    const schedule = () => {
      if (frame) return;
      if (view?.requestAnimationFrame) frame = view.requestAnimationFrame(recount);
      else recount();
    };
    // A look's rows change only with a resize (a digest area opening, a chip chosen).
    const resized = () => {
      if (counters.size === 0) rows = [...element.querySelectorAll<HTMLElement>(".wn-notes-row")];
      schedule();
    };
    if (counters.size === 0) rows = [...element.querySelectorAll<HTMLElement>(".wn-notes-row")];
    recount();
    element.addEventListener("scroll", schedule, { passive: true });
    const resize = typeof ResizeObserver === "function" ? new ResizeObserver(resized) : undefined;
    resize?.observe(element);
    const list = element.querySelector(".wn-notes-list");
    if (list) resize?.observe(list);
    return () => {
      element.removeEventListener("scroll", schedule);
      resize?.disconnect();
      if (frame) view?.cancelAnimationFrame(frame);
    };
  }, [scroller, counters, count, look]);
  return below;
}
