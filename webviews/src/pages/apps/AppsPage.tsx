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
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import type { Strings } from "../shared/i18n";
import { AppDetailView } from "./AppDetailView";
import { CloudFeature } from "./CloudFeature";
import { CustomizeFeature } from "./CustomizeFeature";
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

/** The toolbar's tabs: the store's tabs, plus Examples in the `tab` placement. */
type ToolbarTab = StoreTab | "examples";

export function AppsPage({ store, strings }: { store: AppsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const tabRefs = useRef<Partial<Record<ToolbarTab, HTMLButtonElement>>>({});
  const { t } = strings;
  // A lost owner link keeps the listings it had and says so only once it lasts (a launch, a daemon
  // restart: the store re-reads once the link is back), as a corner mark that takes no room.
  const down = snap.connection === "disconnected";
  const downLasting = useConnectionQuiet(down);
  // The `tab` placement of Examples (DEV, examples=tab) is a third toolbar tab: Discover on the
  // Examples shelf. Every other placement keeps two tabs.
  const examplesTab = snap.examplesOffered && snap.examplesStyle === "tab";
  const tabs: ToolbarTab[] = examplesTab ? ["discover", "examples", "installed"] : ["discover", "installed"];
  const current: ToolbarTab =
    snap.tab === "installed" ? "installed" : examplesTab && snap.shelf === "example" ? "examples" : "discover";
  // Discover is a plain tab change unless the Examples shelf is the one showing.
  const show = (tab: ToolbarTab) => {
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
          value={snap.query}
          // The search filters the list on screen: it stays live while the link comes back (Leo, 2026-11-24 11:57Z).
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
      {downLasting ? <ConnectionChip text={t("store.disconnected")} /> : null}
      {down && snap.catalog.length === 0 && snap.installed.length === 0 ? (
        // Nothing read yet and the link is down: blank, and no false empty shelf either.
        <div className="apps-state" />
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
  const model = useMemo(() => catalogRows(apps, columns, previous.current), [apps, columns]);
  // The committed rows, whose unchanged rows the next build keeps.
  useLayoutEffect(() => {
    previous.current = model;
  }, [model]);
  const { rows, rowOf } = model;
  // The listing that holds focus (a click or Tab focuses one) stays mounted however far it scrolls.
  const [focused, setFocused] = useState<string | undefined>(undefined);
  const kept = [selected, focused].map((id) => (id === undefined ? -1 : (rowOf.get(id) ?? -1)));
  const kind = grid ? `grid:${card}` : "list";
  const sizes = useRef(new Map<string, number>());
  const itemKey = useCallback((index: number) => rows[index]![0]!.id, [rows]);
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns functions the React Compiler cannot memoize safely, so the catalog stays uncompiled on purpose; it lays out rows of columns and keeps the selected and focused listings mounted, so ui/VirtualList does not fit.
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
