// The App Store page (plans/cmux-next/react-pages.md 3.3; behavior of the Swift App Store in
// CmuxNextApps/Store). It fills an app screen or a narrow tab: the grid adapts its columns, the
// detail keeps a readable width, split stacks below 640 px. State lives in `AppsStore`.
import { useRef, useSyncExternalStore, type KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import { AppDetailView } from "./AppDetailView";
import { CloudFeature } from "./CloudFeature";
import { InstalledView } from "./InstalledView";
import { CategoryBar, ItemCard, ItemRow } from "./items";
import type { StoreTab } from "./model";
import type { AppsSnapshot, AppsStore } from "./store";
import { useUiDirection } from "../../ui/UiProvider";

export function AppsPage({ store, strings }: { store: AppsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const tabRefs = useRef<Partial<Record<StoreTab, HTMLButtonElement>>>({});
  const { t } = strings;
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
      {snap.connection === "disconnected" ? (
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
  if (snap.layout !== "split" && selected) {
    return <AppDetailView snap={snap} store={store} strings={strings} showsBack />;
  }
  const framed = !snap.query.trim() && !snap.category && snap.layout === "grid";
  const featured = framed
    ? [...snap.visible]
        .filter((app) => app.tier === "first-party")
        .sort((a, b) => b.install_count - a.install_count || a.name.localeCompare(b.name))
        .slice(0, 2)
    : [];
  const featuredIds = new Set(featured.map((app) => app.id));
  const catalog = featured.length ? snap.visible.filter((app) => !featuredIds.has(app.id)) : snap.visible;
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
              <div className={snap.layout === "grid" ? "apps-grid" : "apps-rows"}>
                {catalog.map((app) =>
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
            </section>
          )}
        </>
      )}
    </div>
  );
  if (snap.layout !== "split") return <div className="apps-scroll">{listing}</div>;
  return (
    <div className="apps-split">
      <div className="apps-split-list">{listing}</div>
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

function LoadingGrid({ strings }: { strings: Strings }) {
  return (
    <div className="apps-grid apps-grid-loading" aria-busy="true" aria-label={strings.t("store.detail.loading")}>
      {Array.from({ length: 6 }, (_, index) => (
        <div className="apps-card-skeleton" key={index} aria-hidden="true">
          <span className="apps-skeleton-icon" />
          <span className="apps-skeleton-line wide" />
          <span className="apps-skeleton-line" />
          <span className="apps-skeleton-footer" />
        </div>
      ))}
    </div>
  );
}
