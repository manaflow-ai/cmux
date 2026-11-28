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
import { CustomizeFeature } from "./CustomizeFeature";
import { CommunityView, useCommunity } from "./CommunityView";
import type { CommunityStore } from "./community";
import { FeaturesView } from "./FeaturesView";
import { InstalledView } from "./InstalledView";
import { CategoryBar, ItemCard, ItemRow, HeroCard, ListRow } from "./items";
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
  categoryLabel,
  featuredApps,
  filterApps,
} from "./model";
import type { AppsSnapshot, AppsStore } from "./store";
import type { CatalogApp } from "./types";
import { Skeleton } from "../../ui/Skeleton";
import { SplitEdge } from "../../ui/SplitEdge";
import { useUiDirection } from "../../ui/UiProvider";
import { ConnectionChip } from "../../ui/ConnectionChip";
import { useConnectionQuiet } from "../../ui/lasting";
import { useAutoRetry } from "../../agent-session/acpmux/autoRetry";

/** The toolbar's tabs: the store's tabs, plus Examples in the `tab` placement, plus Community. */
type ToolbarTab = StoreTab | "examples" | "community";

/** TanStack Virtual's private redraw hook: an own field of each virtualizer (virtual-core 3.17.11
 *  sets it in the constructor), called by `resizeItem` after a size that moves the scroll. */
type PrivateNotify = { notify: (sync: boolean) => void };

/** Whether `virtualizer` has the private `notify` the catalog holds back across a batch of row
 *  resizes. Not public API: a TanStack upgrade can rename or drop it, and the catalog then resizes
 *  rows one at a time (test/apps-virtualizer-notify.test.tsx fails first). */
export function notifiesPrivately(virtualizer: object): boolean {
  return typeof (virtualizer as Partial<PrivateNotify>).notify === "function";
}

export function AppsPage({
  store,
  strings,
  community,
}: {
  store: AppsStore;
  strings: Strings;
  /** The Community tab (community.ts); absent, the page has no Community tab. */
  community?: CommunityStore;
}) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const communitySnap = useCommunity(community);
  const onCommunity = !!community && communitySnap?.active === true;
  const tabRefs = useRef<Partial<Record<ToolbarTab, HTMLButtonElement>>>({});
  const { t } = strings;
  // A lost owner link keeps the listings it had and says so only once it lasts (a launch, a daemon
  // restart: the store re-reads once the link is back), as a corner mark that takes no room.
  const down = snap.connection === "disconnected";
  const downLasting = useConnectionQuiet(down);
  // A catalog read that failed with the link up is read again on its own (the store's `reload`, which
  // also loads a deep-linked detail); the page keeps its loading grid and only a failure that lasts the
  // deadline says one quiet line, with no Reload (Leo, 2026-11-22: "vacuous decisions like that should
  // be just done").
  const catalogFailing = !down && snap.catalogStatus === "error";
  const catalogFailed = catalogFailing ? (snap.catalogError ?? true) : undefined;
  const { stillTrying: catalogStillTrying } = useAutoRetry(catalogFailed, () => void store.reload(), {
    busy: !down && snap.catalogStatus === "loading",
  });
  // The `tab` placement of Examples (DEV, examples=tab) is a third toolbar tab: Discover on the
  // Examples shelf. Every other placement keeps two tabs.
  const examplesTab = snap.examplesOffered && snap.examplesStyle === "tab";
  // Features (Leo, 10-21): every built-in feature as a switch, between Discover and Installed, only
  // while Settings > Advanced > Experiments > App Store Features is on (off by default). A
  // `#/features` route waits on the first read before it falls back to Discover.
  const featuresShown =
    snap.featuresEnabled ||
    (snap.tab === "features" && (snap.featuresStatus === "idle" || snap.featuresStatus === "loading"));
  const tabs: ToolbarTab[] = [
    "discover",
    ...(examplesTab ? (["examples"] as const) : []),
    ...(snap.featuresEnabled ? (["features"] as const) : []),
    ...(community ? (["community"] as const) : []),
    "installed",
  ];
  const onFeatures = snap.tab === "features" && featuresShown;
  const current: ToolbarTab = onCommunity
    ? "community"
    : snap.tab === "installed" || onFeatures
      ? snap.tab
      : examplesTab && snap.shelf === "example"
        ? "examples"
        : "discover";
  // Discover is a plain tab change unless the Examples shelf is the one showing.
  const show = (tab: ToolbarTab) => {
    community?.setActive(tab === "community");
    if (tab === "community") return;
    if (tab === "examples") store.setShelf("example");
    else if (tab === "discover" && snap.shelf === "example") store.setShelf("store");
    else store.setTab(tab);
  };
  const direction = useUiDirection() === "rtl" ? -1 : 1;
  const moveTab = (event: KeyboardEvent<HTMLButtonElement>, tab: ToolbarTab) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const step = event.key === "ArrowRight" ? direction : event.key === "ArrowLeft" ? -direction : null;
    if (event.key !== "Home" && event.key !== "End" && step === null) return;
    const index = tabs.indexOf(tab);
    const next =
      event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : (index + step! + tabs.length) % tabs.length;
    const nextTab = tabs[next]!;
    event.preventDefault();
    show(nextTab);
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
              tabIndex={current === tab ? 0 : -1}
              aria-selected={current === tab}
              className={`apps-tab${current === tab ? " selected" : ""}`}
              onClick={() => show(tab)}
              onKeyDown={(event) => moveTab(event, tab)}
            >
              {tab === "examples" ? t("store.shelf.examples") : t(`store.tab.${tab}`)}
            </button>
          ))}
        </div>
        <input
          className="apps-search"
          type="search"
          placeholder={t("store.search")}
          aria-label={t("store.search")}
          value={onCommunity ? communitySnap!.query : snap.query}
          // The search filters the list on screen: it stays live while the link comes back (Leo, 2026-11-24 11:57Z).
          onChange={(event) =>
            onCommunity ? community!.setQuery(event.target.value) : store.setQuery(event.target.value)
          }
          onKeyDown={(event: KeyboardEvent<HTMLInputElement>) => {
            const query = onCommunity ? communitySnap!.query : snap.query;
            if (event.key === "Escape" && !event.metaKey && !event.ctrlKey && query) {
              if (onCommunity) community!.setQuery("");
              else store.setQuery("");
              event.preventDefault();
            }
          }}
        />
      </header>
      {catalogStillTrying && <output className="apps-error apps-muted">{t("store.stillLoading")}</output>}
      {snap.error && snap.connection !== "disconnected" && (
        <output className="apps-error selectable">{snap.error}</output>
      )}
      {downLasting ? <ConnectionChip text={t("store.disconnected")} /> : null}
      {down && snap.catalog.length === 0 && snap.installed.length === 0 ? (
        // Nothing read yet and the link is down: blank, and no false empty shelf either.
        <div className="apps-state" />
      ) : onCommunity ? (
        <CommunityView snap={communitySnap!} store={community!} strings={strings} />
      ) : onFeatures ? (
        <FeaturesView snap={snap} store={store} strings={strings} />
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
  const onStore = snap.shelf !== "example";
  const home = onStore && !snap.query.trim() && !snap.category;
  // The browse styles (`browse=`) lay out the grid's home; a search, a category, the list and
  // split layouts and the Examples shelf show the plain catalog.
  const framed = home && snap.layout === "grid";
  // The `section` placement (DEV, examples=section) lists the examples under the store's apps.
  // Once per catalog, not per render: the page draws again on each store change.
  const examplesOn = snap.examplesOffered && snap.examplesStyle === "section" && onStore;
  const examplesSection = useMemo(
    () => (examplesOn ? filterApps(snap.catalog, snap.query, undefined, "example") : []),
    [examplesOn, snap.catalog, snap.query],
  );
  // What scrolls the catalog: the page's scroll area, the split's list, or, when the split stacks
  // below 640 px (styles.css), the whole split.
  const stacked = useStackedSplit(snap.layout === "split");
  const scroller = stacked ? ".apps-split" : ".apps-scroll, .apps-split-list";
  if (snap.layout !== "split" && selected) {
    return <AppDetailView snap={snap} store={store} strings={strings} showsBack />;
  }
  const banner = home && (!framed || snap.browse === "pair");
  // Windowed (CatalogList): only the rows near the viewport are mounted.
  const appList = (apps: readonly CatalogApp[]) => (
    <CatalogList
      apps={apps}
      layout={snap.layout}
      card={snap.card}
      selected={snap.layout === "split" ? selected : undefined}
      store={store}
      strings={strings}
      scroller={scroller}
    />
  );
  const listing = (
    <div className="apps-discover-list" data-browse-style={framed ? snap.browse : undefined}>
      {home && <CustomizeFeature store={store} strings={strings} />}
      {banner && <CloudFeature store={store} strings={strings} />}
      <CategoryBar
        categories={snap.categories}
        selected={snap.category}
        onSelect={(category) => store.setCategory(category)}
        examples={
          snap.examplesOffered && snap.examplesStyle === "chip"
            ? { selected: !onStore, onToggle: () => store.setShelf(onStore ? "example" : "store") }
            : undefined
        }
        strings={strings}
      />
      {snap.notice === "notInStore" && <output className="apps-notice">{t("store.notice.notInStore")}</output>}
      {/* A catalog read that failed with the link up keeps the loading grid while the page asks again. */}
      {(snap.loading || (snap.connection !== "disconnected" && snap.catalogStatus === "error")) &&
      snap.visible.length === 0 ? (
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
          {framed ? (
            <BrowseHome snap={snap} store={store} strings={strings} scroller={scroller} />
          ) : (
            <section className="apps-catalog-section" data-store-section="grid" aria-label={t("store.category.all")}>
              {appList(snap.visible)}
            </section>
          )}
          {examplesSection.length > 0 && (
            <section className="apps-catalog-section" aria-labelledby="apps-examples-title">
              <div className="apps-section-heading">
                <h3 id="apps-examples-title">{t("store.shelf.examples")}</h3>
              </div>
              {appList(examplesSection)}
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
  const model = useMemo(() => catalogRows(apps, columns, previous.current), [apps, columns]);
  // The committed rows, whose unchanged rows the next build keeps.
  useLayoutEffect(() => {
    previous.current = model;
  }, [model]);
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
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns functions the React Compiler cannot memoize safely, so the catalog stays uncompiled on purpose; it lays out rows of columns, keeps its own anchor and remeasures on resize, so ui/VirtualList does not fit.
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

/** A titled group of Discover's home: a category, Featured, or the rest. */
function Shelf({
  id,
  title,
  kind = "grid",
  children,
}: {
  id: string;
  title?: string;
  /** `data-store-section` for capture drivers and tests: Featured, or a grid of apps. */
  kind?: "featured" | "grid";
  children: ReactNode;
}) {
  return (
    <section className="apps-catalog-section" data-store-section={kind} aria-labelledby={title ? id : undefined}>
      {title && (
        <div className="apps-section-heading">
          <h3 id={id}>{title}</h3>
        </div>
      )}
      {children}
    </section>
  );
}

/** Few enough apps that each first-party one gets its own hero and no shelf follows. */
const SMALL_STORE = 3;

/**
 * Discover's home in the browse style the route names (model.ts BrowseStyle). `hero`: the top
 * first-party app as a hero (each of them, in a small store), then a shelf per category with two or
 * more apps and one for the rest. `pair`: two featured cards, then every app. `list`: store rows.
 */
function BrowseHome({
  snap,
  store,
  strings,
  scroller,
}: {
  snap: AppsSnapshot;
  store: AppsStore;
  strings: Strings;
  scroller: string;
}) {
  const { t } = strings;
  const apps = snap.visible;
  // Once per catalog, not per render: the page draws again on each store change, and the grids
  // below are windowed (CatalogList), which keep their rows while their listings stay the same.
  const { featured, rest, shelves } = useMemo(() => {
    if (snap.browse === "list") return { featured: [], rest: [], shelves: [] };
    const featured = featuredApps(apps, snap.browse === "pair" ? 2 : apps.length <= SMALL_STORE ? 2 : 1);
    const ids = new Set(featured.map((app) => app.id));
    const rest = apps.filter((app) => !ids.has(app.id));
    return { featured, rest, shelves: snap.browse === "pair" ? [] : categoryShelves(rest) };
  }, [apps, snap.browse]);
  const grid = (list: readonly CatalogApp[]) => (
    <CatalogList apps={list} layout="grid" card={snap.card} store={store} strings={strings} scroller={scroller} />
  );
  if (snap.browse === "list") {
    return (
      <Shelf id="apps-all-title">
        <div className="apps-list">
          {apps.map((app) => (
            <ListRow key={app.id} app={app} store={store} strings={strings} />
          ))}
        </div>
      </Shelf>
    );
  }
  if (snap.browse === "pair") {
    return (
      <>
        {featured.length > 0 && (
          <Shelf id="apps-featured-title" title={t("store.browse.featured")} kind="featured">
            <div className="apps-featured-grid">
              {featured.map((app) => (
                <ItemCard key={app.id} app={app} store={store} strings={strings} style={snap.card} featured />
              ))}
            </div>
          </Shelf>
        )}
        {rest.length > 0 && (
          <Shelf id="apps-all-title" title={featured.length ? t("store.browse.allApps") : undefined}>
            {grid(rest)}
          </Shelf>
        )}
      </>
    );
  }
  const heroes = featured;
  return (
    <>
      {heroes.length > 0 && (
        <div className="apps-heroes" data-store-section="featured">
          {heroes.map((app) => (
            <HeroCard key={app.id} app={app} preview={snap.previews[app.id]} store={store} strings={strings} />
          ))}
        </div>
      )}
      {shelves.map(({ category, apps: shelf }) => (
        <Shelf
          key={category ?? ""}
          id={`apps-shelf-${category ?? "more"}`}
          title={
            category
              ? categoryLabel(category, t)
              : heroes.length > 0 || shelves.length > 1
                ? t(shelves.length > 1 ? "store.browse.more" : "store.browse.allApps")
                : undefined
          }
        >
          {grid(shelf)}
        </Shelf>
      ))}
    </>
  );
}

/**
 * Shelves by each app's first category, biggest first: a category with two or more apps gets its
 * own shelf, the rest share one untitled shelf at the end (`category` undefined).
 */
function categoryShelves(apps: readonly CatalogApp[]): { category?: string; apps: CatalogApp[] }[] {
  const by = new Map<string, CatalogApp[]>();
  for (const app of apps) {
    const category = app.categories[0] ?? "";
    const list = by.get(category);
    if (list) list.push(app);
    else by.set(category, [app]);
  }
  const shelves = [...by]
    .filter(([category, list]) => category && list.length >= 2)
    .sort((a, b) => b[1].length - a[1].length)
    .map(([category, list]) => ({ category, apps: list }));
  const shelved = new Set(shelves.flatMap((shelf) => shelf.apps.map((app) => app.id)));
  const rest = apps.filter((app) => !shelved.has(app.id));
  return rest.length ? [...shelves, { apps: rest }] : shelves;
}

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
