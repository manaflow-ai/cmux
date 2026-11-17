// The App Store page (plans/cmux-next/react-pages.md 3.3; behavior of the Swift App Store in
// CmuxNextApps/Store). It fills an app screen or a narrow tab: the grid adapts its columns, the
// detail keeps a readable width, split stacks below 640 px. State lives in `AppsStore`.
import { useRef, useSyncExternalStore, type KeyboardEvent, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { AppDetailView } from "./AppDetailView";
import { CloudFeature } from "./CloudFeature";
import { CommunityView, useCommunity } from "./CommunityView";
import type { CommunityStore } from "./community";
import { InstalledView } from "./InstalledView";
import { CategoryBar, HeroCard, ItemCard, ItemRow, ListRow } from "./items";
import { categoryLabel, featuredApps, filterApps, type StoreTab } from "./model";
import type { AppsSnapshot, AppsStore } from "./store";
import type { CatalogApp } from "./types";
import { Skeleton } from "../../ui/Skeleton";
import { SplitEdge } from "../../ui/SplitEdge";
import { useUiDirection } from "../../ui/UiProvider";
import { useLasting } from "../../ui/lasting";

/** The toolbar's tabs: the store's tabs, plus Examples in the `tab` placement, plus Community. */
type ToolbarTab = StoreTab | "examples" | "community";

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
  // A lost owner link shows nothing until it lasts past the grace (a launch, a daemon restart:
  // the store re-reads once the link is back); then the disconnected state.
  const down = snap.connection === "disconnected";
  const downLasting = useLasting(down);
  // The `tab` placement of Examples (DEV, examples=tab) is a third toolbar tab: Discover on the
  // Examples shelf. Every other placement keeps two tabs.
  const examplesTab = snap.examplesOffered && snap.examplesStyle === "tab";
  const storeTabs: ToolbarTab[] = examplesTab ? ["discover", "examples", "installed"] : ["discover", "installed"];
  const tabs: ToolbarTab[] = community ? [...storeTabs.slice(0, -1), "community", "installed"] : storeTabs;
  const current: ToolbarTab = onCommunity
    ? "community"
    : snap.tab === "installed"
      ? "installed"
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
          disabled={snap.connection === "disconnected"}
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
      ) : onCommunity ? (
        <CommunityView snap={communitySnap!} store={community!} strings={strings} />
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
  if (snap.layout !== "split" && selected) {
    return <AppDetailView snap={snap} store={store} strings={strings} showsBack />;
  }
  const onStore = snap.shelf !== "example";
  const home = onStore && !snap.query.trim() && !snap.category;
  // The browse styles (`browse=`) lay out the grid's home; a search, a category, the list and
  // split layouts and the Examples shelf show the plain catalog.
  const framed = home && snap.layout === "grid";
  // The `section` placement (DEV, examples=section) lists the examples under the store's apps.
  const examplesSection =
    snap.examplesOffered && snap.examplesStyle === "section" && onStore
      ? filterApps(snap.catalog, snap.query, undefined, "example")
      : [];
  const banner = home && (!framed || snap.browse === "pair");
  const appList = (apps: readonly CatalogApp[]) => (
    <div className={snap.layout === "grid" ? "apps-grid" : "apps-rows"}>
      {apps.map((app) =>
        snap.layout === "grid" ? (
          <ItemCard key={app.id} app={app} store={store} strings={strings} style={snap.card} />
        ) : (
          <ItemRow
            key={app.id}
            app={app}
            selected={snap.layout === "split" && app.id === selected}
            store={store}
            strings={strings}
          />
        ),
      )}
    </div>
  );
  const listing = (
    <div className="apps-discover-list" data-browse-style={framed ? snap.browse : undefined}>
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
            <BrowseHome snap={snap} store={store} strings={strings} />
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
function BrowseHome({ snap, store, strings }: { snap: AppsSnapshot; store: AppsStore; strings: Strings }) {
  const { t } = strings;
  const apps = snap.visible;
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
    const featured = featuredApps(apps, 2);
    const ids = new Set(featured.map((app) => app.id));
    const rest = apps.filter((app) => !ids.has(app.id));
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
            <div className="apps-grid">
              {rest.map((app) => (
                <ItemCard key={app.id} app={app} store={store} strings={strings} style={snap.card} />
              ))}
            </div>
          </Shelf>
        )}
      </>
    );
  }
  const heroes = featuredApps(apps, apps.length <= SMALL_STORE ? 2 : 1);
  const ids = new Set(heroes.map((app) => app.id));
  const rest = apps.filter((app) => !ids.has(app.id));
  const shelves = categoryShelves(rest);
  const card = (app: CatalogApp) => (
    <ItemCard key={app.id} app={app} store={store} strings={strings} style={snap.card} />
  );
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
          <div className="apps-grid">{shelf.map(card)}</div>
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
    by.set(category, [...(by.get(category) ?? []), app]);
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
