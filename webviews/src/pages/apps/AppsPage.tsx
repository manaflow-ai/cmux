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
} from "react";
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
 * selection are never unmounted. The first measured row of each kind sizes the rows not yet
 * mounted. Rows and cards are memoized on their listings, so a change to one listing draws its own
 * card, and a scroll step draws only the rows it brings in.
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
  const place = useCallback(() => {
    const element = space.current;
    const scroll = scrollElement();
    if (!element || !scroll) return;
    const width = element.offsetWidth;
    const margin = Math.round(
      element.getBoundingClientRect().top - scroll.getBoundingClientRect().top + scroll.scrollTop,
    );
    setBox((old) => (old.width === width && old.margin === margin ? old : { width, margin }));
  }, [scrollElement]);
  useLayoutEffect(place, [place, apps.length === 0, layout, card]);
  useEffect(() => {
    const listing = space.current?.closest(".apps-discover-list");
    if (!listing || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(place);
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
  // The listing that holds focus (a click or Tab focuses one) stays mounted however far it scrolls.
  const [focused, setFocused] = useState<string | undefined>(undefined);
  const kept = [selected, focused].map((id) => (id === undefined ? -1 : (rowOf.get(id) ?? -1)));
  const kind = grid ? `grid:${card}` : "list";
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
      for (const index of kept)
        if (index >= 0 && !indexes.includes(index)) {
          indexes.push(index);
          indexes.sort((a, b) => a - b);
        }
      return indexes;
    },
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
  return (
    <div
      ref={space}
      className="apps-catalog-space"
      role={grid ? undefined : "list"}
      style={{ height: virtualizer.getTotalSize() }}
      onFocus={(event) => setFocused((event.target as HTMLElement).closest<HTMLElement>("[data-app]")?.dataset.app)}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setFocused(undefined);
      }}
    >
      {virtualizer
        .getVirtualItems()
        .map(({ index, key, start }) =>
          grid ? (
            <CatalogGridRow
              key={key}
              index={index}
              top={start - box.margin}
              size={kind}
              apps={rows[index]!}
              first={index * columns}
              count={apps.length}
              card={card}
              store={store}
              strings={strings}
              measure={measure}
            />
          ) : (
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
          ),
        )}
    </div>
  );
}

/** Where a windowed row sits: its index (TanStack measures it by `data-index`) and offset. */
interface Placed {
  index: number;
  top: number;
  measure: (element: HTMLElement | null) => void;
  /** Every listing in the catalog: the screen reader's "3 of 1000". */
  count: number;
  store: AppsStore;
  strings: Strings;
}

/** One row of the grid: the same `auto-fill` grid as before, holding one row's cards. */
const CatalogGridRow = memo(function CatalogGridRow({
  index,
  top,
  size,
  measure,
  apps,
  first,
  count,
  card,
  store,
  strings,
}: Placed & { size: string; apps: readonly CatalogApp[]; first: number; card: CardStyle }) {
  return (
    <div
      ref={measure}
      data-index={index}
      data-size={size}
      className="apps-grid"
      style={{ transform: `translateY(${top}px)` }}
    >
      {apps.map((app, column) => (
        <ItemCard
          key={app.id}
          app={app}
          store={store}
          strings={strings}
          style={card}
          position={first + column + 1}
          count={count}
        />
      ))}
    </div>
  );
});

/** One row of the list and split layouts. */
const CatalogListRow = memo(function CatalogListRow({
  index,
  top,
  measure,
  app,
  count,
  selected,
  store,
  strings,
}: Placed & { app: CatalogApp; selected: boolean }) {
  return (
    <div
      ref={measure}
      data-index={index}
      data-size="list"
      data-app={app.id}
      // A positioned row of the windowed list (no list markers or spacing to reset), as in the grid.
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
