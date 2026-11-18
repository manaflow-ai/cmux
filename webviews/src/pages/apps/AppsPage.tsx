// The App Store page (plans/cmux-next/react-pages.md 3.3; behavior of the Swift App Store in
// CmuxNextApps/Store). It fills an app screen or a narrow tab: the grid adapts its columns, the
// detail keeps a readable width, split stacks below 640 px. State lives in `AppsStore`.
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { flushSync } from "react-dom";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import type { Strings } from "../shared/i18n";
import { AppDetailView } from "./AppDetailView";
import { CloudFeature } from "./CloudFeature";
import { InstalledView } from "./InstalledView";
import { CategoryBar, ItemCard, ItemRow } from "./items";
import {
  catalogRows,
  GRID_GAP,
  GRID_ROW_ESTIMATE,
  gridColumns,
  LIST_GAP,
  LIST_ROW_ESTIMATE,
  type CardStyle,
  type CatalogRows,
  type StoreLayout,
  type StoreTab,
} from "./model";
import type { CatalogApp } from "./types";
import type { AppsSnapshot, AppsStore } from "./store";
import { Skeleton } from "../../ui/Skeleton";
import { SplitEdge } from "../../ui/SplitEdge";
import { useUiDirection } from "../../ui/UiProvider";
import { useLasting } from "../../ui/lasting";

/** TanStack Virtual's private redraw hook: an own field of each virtualizer (virtual-core 3.17.11
 *  sets it in the constructor), called by `resizeItem` after a size that moves the scroll. */
type PrivateNotify = { notify: (sync: boolean) => void };

/** Whether `virtualizer` has the private `notify` the catalog holds back across a batch of row
 *  resizes. Not public API: a TanStack upgrade can rename or drop it, and the catalog then resizes
 *  rows one at a time (test/apps-virtualizer-notify.test.tsx fails first). */
export function notifiesPrivately(virtualizer: object): boolean {
  return typeof (virtualizer as Partial<PrivateNotify>).notify === "function";
}

export function AppsPage({ store, strings }: { store: AppsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const tabRefs = useRef<Partial<Record<StoreTab, HTMLButtonElement>>>({});
  const { t } = strings;
  // A lost owner link shows nothing until it lasts past the grace (a launch, a daemon restart:
  // the store re-reads once the link is back); then the disconnected state.
  const down = snap.connection === "disconnected";
  const downLasting = useLasting(down);
  const tabs: StoreTab[] = ["discover", "installed"];
  const direction = useUiDirection() === "rtl" ? -1 : 1;
  const moveTab = (event: KeyboardEvent<HTMLButtonElement>, tab: StoreTab) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const step = event.key === "ArrowRight" ? direction : event.key === "ArrowLeft" ? -direction : null;
    if (event.key !== "Home" && event.key !== "End" && step === null) return;
    const current = tabs.indexOf(tab);
    const next =
      event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : (current + step! + tabs.length) % tabs.length;
    const nextTab = tabs[next]!;
    event.preventDefault();
    store.setTab(nextTab);
    tabRefs.current[nextTab]?.focus();
  };
  return (
    <div className="apps-page">
      <header className="apps-toolbar">
        <div className="apps-tabs" role="tablist">
          {tabs.map((tab) => (
            <button
              key={tab}
              type="button"
              role="tab"
              ref={(element) => {
                tabRefs.current[tab] = element ?? undefined;
              }}
              tabIndex={snap.tab === tab ? 0 : -1}
              aria-selected={snap.tab === tab}
              className={`apps-tab${snap.tab === tab ? " selected" : ""}`}
              onClick={() => store.setTab(tab)}
              onKeyDown={(event) => moveTab(event, tab)}
            >
              {t(`store.tab.${tab}`)}
            </button>
          ))}
        </div>
        <input
          className="apps-search"
          type="search"
          placeholder={t("store.search")}
          aria-label={t("store.search")}
          value={snap.query}
          disabled={snap.connection === "disconnected"}
          onChange={(event) => store.setQuery(event.target.value)}
          onKeyDown={(event: KeyboardEvent<HTMLInputElement>) => {
            if (event.key === "Escape" && !event.metaKey && !event.ctrlKey && snap.query) {
              store.setQuery("");
              event.preventDefault();
            }
          }}
        />
      </header>
      {snap.catalogError && snap.connection !== "disconnected" && (
        <div className="apps-error" role="alert">
          <span className="apps-error-copy">
            <strong>{t("store.error.load")}</strong>
            <span className="selectable">{snap.catalogError}</span>
          </span>
          <button type="button" className="apps-button" onClick={() => void store.reload()}>
            {t("store.action.reload")}
          </button>
        </div>
      )}
      {snap.error && snap.connection !== "disconnected" && (
        <output className="apps-error selectable">{snap.error}</output>
      )}
      {down && !downLasting ? null : down ? (
        <output className="apps-state">
          <span className="apps-state-mark" aria-hidden="true">
            !
          </span>
          <strong>{t("store.window.title")}</strong>
          <span>{t("store.disconnected")}</span>
        </output>
      ) : snap.tab === "installed" ? (
        <InstalledView snap={snap} store={store} strings={strings} />
      ) : (
        <Discover snap={snap} store={store} strings={strings} />
      )}
    </div>
  );
}

function Discover({ snap, store, strings }: { snap: AppsSnapshot; store: AppsStore; strings: Strings }) {
  const { t } = strings;
  const selected = snap.selection;
  const framed = !snap.query.trim() && !snap.category && snap.layout === "grid";
  // Once per catalog, not per render: the page draws again on each store change.
  const { featured, catalog } = useMemo(() => {
    const featured = framed
      ? snap.visible
          .filter((app) => app.tier === "first-party")
          .sort((a, b) => b.install_count - a.install_count || a.name.localeCompare(b.name))
          .slice(0, 2)
      : [];
    const featuredIds = new Set(featured.map((app) => app.id));
    return {
      featured,
      catalog: featured.length ? snap.visible.filter((app) => !featuredIds.has(app.id)) : snap.visible,
    };
  }, [framed, snap.visible]);
  // What scrolls the catalog: the page's scroll area, the split's list, or, when the split stacks
  // below 640 px (styles.css), the whole split.
  const stacked = useStackedSplit(snap.layout === "split");
  const scroller = stacked ? ".apps-split" : ".apps-scroll, .apps-split-list";
  if (snap.layout !== "split" && selected) {
    return <AppDetailView snap={snap} store={store} strings={strings} showsBack />;
  }
  const listing = (
    <div className="apps-discover-list">
      {!snap.query.trim() && !snap.category && <CloudFeature store={store} strings={strings} />}
      <CategoryBar
        categories={snap.categories}
        selected={snap.category}
        onSelect={(category) => store.setCategory(category)}
        strings={strings}
      />
      {snap.loading && snap.visible.length === 0 ? (
        <LoadingGrid strings={strings} />
      ) : snap.visible.length === 0 && snap.catalogStatus === "error" ? null : snap.visible.length === 0 ? (
        <output className="apps-state apps-state-empty">
          <span className="apps-state-mark" aria-hidden="true">
            ⌕
          </span>
          <strong>{t("store.empty.noMatches")}</strong>
          <span>{t("store.search")}</span>
        </output>
      ) : (
        <>
          {featured.length > 0 && (
            <section className="apps-catalog-section" aria-labelledby="apps-featured-title">
              <div className="apps-section-heading">
                <h3 id="apps-featured-title">{t("store.tier.firstParty")}</h3>
              </div>
              <div className="apps-featured-grid">
                {featured.map((app) => (
                  <ItemCard key={app.id} app={app} store={store} strings={strings} style={snap.card} featured />
                ))}
              </div>
            </section>
          )}
          {catalog.length > 0 && (
            <section
              className="apps-catalog-section"
              aria-labelledby={featured.length > 0 ? "apps-catalog-title" : undefined}
              aria-label={featured.length > 0 ? undefined : t("store.category.all")}
            >
              {featured.length > 0 && (
                <div className="apps-section-heading">
                  <h3 id="apps-catalog-title">{t("store.category.all")}</h3>
                </div>
              )}
              <CatalogList
                apps={catalog}
                layout={snap.layout}
                card={snap.card}
                selected={snap.layout === "split" ? selected : undefined}
                store={store}
                strings={strings}
                scroller={scroller}
              />
            </section>
          )}
        </>
      )}
    </div>
  );
  if (snap.layout !== "split") return <div className="apps-scroll">{listing}</div>;
  return (
    <div className="apps-split">
      <div className="apps-split-side">
        <div className="apps-split-list">{listing}</div>
        {/* The list's line is the split's divider and drags as one (ui/SplitEdge.tsx). */}
        <SplitEdge
          side="right"
          property="--apps-list-width"
          storageKey="cmux.apps.list.width"
          min={200}
          max={560}
          on="parent"
        />
      </div>
      <div className="apps-split-detail">
        {selected ? (
          <AppDetailView snap={snap} store={store} strings={strings} />
        ) : (
          <div className="apps-empty">{t("store.empty.select")}</div>
        )}
      </div>
    </div>
  );
}

/** Whether the split view stacks its list above the detail (styles.css, max-width 640 px). */
const STACKED = "(max-width: 640px)";
function useStackedSplit(split: boolean): boolean {
  const query = useMemo(
    () => (split && typeof window.matchMedia === "function" ? window.matchMedia(STACKED) : undefined),
    [split],
  );
  const subscribe = useCallback(
    (changed: () => void) => {
      query?.addEventListener("change", changed);
      return () => query?.removeEventListener("change", changed);
    },
    [query],
  );
  const stacked = useCallback(() => query?.matches ?? false, [query]);
  return useSyncExternalStore(subscribe, stacked, stacked);
}

/** About a viewport of rows above and below the visible ones: grid rows, or list rows. */
const GRID_OVERSCAN = 6;
const LIST_OVERSCAN = 16;

/**
 * The catalog, windowed: only the rows near the viewport are mounted (a grid row holds as many
 * cards as the grid has columns), plus the selected and the focused row so focus and the split's
 * selection are never unmounted, and the focused row's neighbours and the first and last rows, so
 * the browser's own Tab and Shift-Tab keep listing order (no key handler). The first measured row
 * of each kind sizes the rows not yet mounted. Rows and cards are memoized on their listings, so a
 * change to one listing draws its own card, and a scroll step draws only the rows it brings in.
 *
 * The grid is one CSS grid of cards keyed by listing, in listing order, with a full-width spacer for
 * each run of rows not mounted: a column change moves each mounted card to its new row and column
 * without mounting it again or drawing it (a row of its own would hold other listings after one).
 */
function CatalogList({
  apps,
  layout,
  card,
  selected,
  store,
  strings,
  scroller,
}: {
  apps: readonly CatalogApp[];
  layout: StoreLayout;
  card: CardStyle;
  selected?: string;
  store: AppsStore;
  strings: Strings;
  /** The ancestor that scrolls the catalog. Found from the catalog's own node: on mount this
   *  component's layout effects run before an ancestor's ref is set. */
  scroller: string;
}) {
  const space = useRef<HTMLDivElement | null>(null);
  const scrollElement = useCallback(() => space.current?.closest<HTMLElement>(scroller) ?? null, [scroller]);
  const grid = layout === "grid";
  // The catalog's width (for its columns) and its offset in the scroll area (the banner, chips and
  // featured row above it), read on mount and when the listing around it resizes.
  const [box, setBox] = useState({ width: 0, margin: 0 });
  // A width that changes the grid's columns moves every listing to another row. The first row in
  // view is held, by its first listing and its distance below the viewport's top, and the scroll
  // that keeps it there is worked out before the rows are built again (`hold`, set below).
  const anchor = useRef<Anchor>({ hold: () => undefined, remeasure: () => {}, restore: () => {} });
  // `resized`: the listing's resize, the one place the width changes. A column change there draws
  // the new rows at the held row's new scroll, in one draw, before the frame paints: a frame of the
  // old rows at the new width shows other listings, and a draw at the old scroll mounts listings the
  // held row's scroll would unmount again.
  const place = useCallback(
    (resized = false) => {
      const element = space.current;
      const scroll = scrollElement();
      if (!element || !scroll) return;
      const width = element.offsetWidth;
      const margin = Math.round(
        element.getBoundingClientRect().top - scroll.getBoundingClientRect().top + scroll.scrollTop,
      );
      const update = () => setBox((old) => (old.width === width && old.margin === margin ? old : { width, margin }));
      const target = resized ? anchor.current.hold(width, margin) : undefined;
      if (target === undefined) return update();
      flushSync(() => {
        update();
        anchor.current.remeasure();
        // TanStack reads the new scroll in this same draw (its scroll handler draws it, with the
        // new width, at once).
        scroll.scrollTop = target;
        scroll.dispatchEvent(new Event("scroll"));
      });
      anchor.current.restore();
    },
    [scrollElement],
  );
  const placeLayout = useCallback(() => place(), [place]);
  useLayoutEffect(placeLayout, [placeLayout, apps.length === 0, layout, card]);
  useEffect(() => {
    const listing = space.current?.closest(".apps-discover-list");
    if (!listing || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => place(true));
    observer.observe(listing);
    return () => observer.disconnect();
  }, [place]);
  const columns = grid ? gridColumns(box.width) : 1;
  const previous = useRef<CatalogRows | undefined>(undefined);
  const model = useMemo(() => {
    const next = catalogRows(apps, columns, previous.current);
    previous.current = next;
    return next;
  }, [apps, columns]);
  const { rows, rowOf } = model;
  // The listing that holds focus (a click or Tab focuses one) stays mounted however far it scrolls;
  // so do the rows before and after it and the first and last rows, the browser's next tab stops:
  // Tab and Shift-Tab go on in listing order, and into the catalog at its first or last listing.
  const [focused, setFocused] = useState<string | undefined>(undefined);
  const focusedRow = focused === undefined ? -1 : (rowOf.get(focused) ?? -1);
  const kept = [0, rows.length - 1, selected === undefined ? -1 : (rowOf.get(selected) ?? -1)];
  if (focusedRow >= 0) kept.push(focusedRow - 1, focusedRow, focusedRow + 1);
  // A grid row's height follows its cards' width (a description wraps to more or fewer lines), so a
  // grid row's estimate is learned per column count.
  const kind = grid ? `grid:${card}:${columns}` : "list";
  const sizes = useRef(new Map<string, number>());
  const itemKey = useCallback((index: number) => rows[index]![0]!.id, [rows]);
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: scrollElement,
    estimateSize: () => sizes.current.get(kind) ?? (grid ? GRID_ROW_ESTIMATE : LIST_ROW_ESTIMATE),
    getItemKey: itemKey,
    gap: grid ? GRID_GAP : LIST_GAP,
    overscan: grid ? GRID_OVERSCAN : LIST_OVERSCAN,
    scrollMargin: box.margin,
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      for (const index of kept) if (index >= 0 && index < rows.length && !indexes.includes(index)) indexes.push(index);
      return indexes.sort((a, b) => a - b);
    },
  });
  // A grid row is as tall as its tallest card, and each of its cards is stretched to that height:
  // one observer of the mounted cards sizes each one's row (found by its listing). Cards laid out at
  // a width the rows were not built for (the columns changed, and the rows are not yet built again)
  // are not read: they sit in other rows for that moment.
  const cards = useRef<{ observer?: ResizeObserver; observed: Set<HTMLElement> }>({ observed: new Set() });
  // Checked once per virtualizer (the hook keeps one for the page's life).
  const notifies = useMemo(() => notifiesPrivately(virtualizer), [virtualizer]);
  const current = useRef({ columns, rowOf, kind, virtualizer, notifies });
  const observeCard = useCallback((node: HTMLElement | null) => {
    if (!node || typeof ResizeObserver === "undefined") return;
    const own = cards.current;
    own.observer ??= new ResizeObserver((entries) => {
      const { columns, rowOf, kind, virtualizer, notifies } = current.current;
      const element = space.current;
      if (!element || gridColumns(element.offsetWidth) !== columns) return;
      const resizeRows = () => {
        for (const entry of entries) {
          const row = rowOf.get((entry.target as HTMLElement).dataset.app ?? "");
          const size = Math.round(entry.borderBoxSize?.[0]?.blockSize ?? (entry.target as HTMLElement).offsetHeight);
          if (row === undefined || !(size > 0)) continue;
          if (!sizes.current.has(kind)) sizes.current.set(kind, size);
          virtualizer.resizeItem(row, size);
        }
      };
      // TanStack draws the catalog again, at once, after each row whose new size moves the scroll
      // (a row above the view), and the next row's resize then reads the layout that draw dirtied: a
      // width step drew and laid out the catalog once per row above the view. The cards are laid
      // out in the catalog's flow, so no draw is needed between rows: one, after them all. This
      // holds back TanStack's private `notify` (see `notifiesPrivately`); a TanStack without it
      // gets the rows one at a time, as before.
      if (!notifies) return resizeRows();
      const instance = virtualizer as unknown as PrivateNotify;
      const notify = instance.notify;
      let sync: boolean | undefined;
      instance.notify = (now) => {
        sync = sync === true || now;
      };
      try {
        resizeRows();
      } finally {
        instance.notify = notify;
      }
      if (sync !== undefined) notify(sync);
    });
    own.observer.observe(node);
    own.observed.add(node);
    return () => {
      own.observer?.unobserve(node);
      own.observed.delete(node);
    };
  }, []);
  useEffect(() => () => cards.current.observer?.disconnect(), []);
  // Across the draw between `hold` and `restore`.
  const held = useRef<{ id: string; offset: number } | undefined>(undefined);
  useLayoutEffect(() => {
    current.current = { columns, rowOf, kind, virtualizer, notifies };
    anchor.current = {
      hold: (width, margin) => {
        const scroll = scrollElement();
        const element = space.current;
        const next = gridColumns(width);
        if (!grid || !scroll || !element || next === columns) return undefined;
        held.current = undefined;
        // Where the rows are now: placed for the old margin, in a catalog that starts at the new one
        // (the banner and chips above re-wrap; the browser may have moved the scroll to hold what is
        // in view).
        const top = scroll.scrollTop + virtualizer.options.scrollMargin - margin;
        // The first row that reaches into the view, though its top may be above it (a row cut by the
        // top is the one the reader sees first): its offset from the top is held, negative then. The
        // mounted rows only (about two viewports of them, in order), once per column change.
        const found = virtualizer.getVirtualItems().find((item) => item.end > top);
        const item = found && found.start < top + scroll.clientHeight ? found : undefined;
        if (!item) return scroll.scrollTop;
        // The new columns' row height: learned, or read from a card the browser has already laid
        // out at the new width (this runs after layout, so the read costs no layout).
        const nextKind = `grid:${card}:${next}`;
        const sample = element.querySelector<HTMLElement>(":scope > [data-app]")?.offsetHeight;
        if (!sizes.current.has(nextKind) && sample) sizes.current.set(nextKind, sample);
        const size = sizes.current.get(nextKind) ?? GRID_ROW_ESTIMATE;
        const offset = item.start - top;
        held.current = { id: rows[item.index]![0]!.id, offset };
        // The held row's first listing, its row at the new columns, and that row's start once every
        // row is at the estimate (as TanStack places them: from the margin, a gap after each).
        const row = Math.floor((item.index * columns) / next);
        return Math.max(0, margin + row * (size + GRID_GAP) - offset);
      },
      // The sizes measured at the old column count are not this one's: every row is placed again by
      // the estimate, and re-measured as its cards report their size (`restore`).
      remeasure: () => virtualizer.measure(),
      restore: () => {
        const scroll = scrollElement();
        const hold = held.current;
        held.current = undefined;
        // Each mounted card reports its size at the new columns, for its row (in this frame: the
        // cards are deeper than the listing whose resize this is).
        const { observer, observed } = cards.current;
        if (observer)
          for (const node of observed) {
            observer.unobserve(node);
            observer.observe(node);
          }
        if (!hold || !scroll) return;
        const row = rowOf.get(hold.id);
        virtualizer.getTotalSize();
        const start = row === undefined ? undefined : virtualizer.measurementsCache[row]?.start;
        if (start === undefined) return;
        // The scroll was worked out from the estimate; put it right if the rows placed otherwise
        // (the end of the catalog clamps it).
        const target = Math.max(0, start - hold.offset);
        if (Math.abs(scroll.scrollTop - target) < 1) return;
        scroll.scrollTop = target;
        scroll.dispatchEvent(new Event("scroll"));
      },
    };
  });
  // The first mounted row of each kind sizes every one not yet mounted, so the rows a scroll brings
  // in measure as estimated: TanStack places all N rows again whenever a measure differs.
  const measure = useCallback(
    (node: HTMLElement | null) => {
      const size = node?.dataset.size;
      if (node && size && !sizes.current.has(size) && node.offsetHeight > 0) sizes.current.set(size, node.offsetHeight);
      virtualizer.measureElement(node);
    },
    [virtualizer],
  );
  const items = virtualizer.getVirtualItems();
  if (grid) {
    // Cards in listing order, so Tab, Shift-Tab and a screen reader go through the listings in order.
    const cells: ReactNode[] = [];
    let end: number | undefined;
    let last = -1;
    let gaps = 0;
    for (const { index, start, size } of items) {
      if (index > last + 1) {
        // The rows between, at their sizes, less the grid's gaps around the spacer.
        const height = end === undefined ? start - box.margin - GRID_GAP : start - end - 2 * GRID_GAP;
        cells.push(
          <div
            key={`gap:${gaps++}`}
            className="apps-catalog-gap"
            aria-hidden="true"
            style={{ height: Math.max(0, height) }}
          />,
        );
      }
      rows[index]!.forEach((app, column) =>
        cells.push(
          <ItemCard
            key={app.id}
            ref={observeCard}
            app={app}
            store={store}
            strings={strings}
            style={card}
            position={index * columns + column + 1}
            count={apps.length}
          />,
        ),
      );
      end = start + size;
      last = index;
    }
    return (
      <div
        ref={space}
        className="apps-catalog-space apps-grid"
        onFocus={(event) => setFocused((event.target as HTMLElement).closest<HTMLElement>("[data-app]")?.dataset.app)}
        onBlur={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget)) setFocused(undefined);
        }}
      >
        {cells}
      </div>
    );
  }
  return (
    <div
      ref={space}
      className="apps-catalog-space"
      // The windowed list's positioned rows (no list markers or spacing to reset).
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="list"
      style={{ height: virtualizer.getTotalSize() }}
      onFocus={(event) => setFocused((event.target as HTMLElement).closest<HTMLElement>("[data-app]")?.dataset.app)}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setFocused(undefined);
      }}
    >
      {items.map(({ index, key, start }) => (
        <CatalogListRow
          key={key}
          index={index}
          top={start - box.margin}
          app={rows[index]![0]!}
          count={apps.length}
          selected={rows[index]![0]!.id === selected}
          store={store}
          strings={strings}
          measure={measure}
        />
      ))}
    </div>
  );
}

/** Holds the catalog's first row in view across a column change: `hold`, with the new width and
 *  margin, gives the scroll that keeps it in place once the rows are built for the new columns
 *  (undefined when the columns do not change); `remeasure`, in that draw, drops the old columns'
 *  row sizes; `restore`, after it, measures the new rows and puts the scroll right if they placed
 *  otherwise. */
interface Anchor {
  hold: (width: number, margin: number) => number | undefined;
  remeasure: () => void;
  restore: () => void;
}

/** One row of the list and split layouts: its index (TanStack measures it by `data-index`) and
 *  offset. */
const CatalogListRow = memo(function CatalogListRow({
  index,
  top,
  measure,
  app,
  count,
  selected,
  store,
  strings,
}: {
  index: number;
  top: number;
  measure: (element: HTMLElement | null) => void;
  app: CatalogApp;
  /** Every listing in the catalog: the screen reader's "3 of 1000". */
  count: number;
  selected: boolean;
  store: AppsStore;
  strings: Strings;
}) {
  return (
    <div
      ref={measure}
      data-index={index}
      data-size="list"
      data-app={app.id}
      // A positioned row of the windowed list (no list markers or spacing to reset).
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listitem"
      aria-posinset={index + 1}
      aria-setsize={count}
      style={{ transform: `translateY(${top}px)` }}
    >
      <ItemRow app={app} selected={selected} store={store} strings={strings} />
    </div>
  );
});

function LoadingGrid({ strings }: { strings: Strings }) {
  return (
    <div className="apps-grid apps-grid-loading" aria-busy="true" aria-label={strings.t("store.detail.loading")}>
      {Array.from({ length: 6 }, (_, index) => (
        <div className="apps-card-skeleton" key={index} aria-hidden="true">
          <Skeleton className="apps-skeleton-icon" />
          <Skeleton className="apps-skeleton-line wide" />
          <Skeleton className="apps-skeleton-line" />
          <Skeleton className="apps-skeleton-footer" />
        </div>
      ))}
    </div>
  );
}
