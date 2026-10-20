// The App Store page (plans/cmux-next/react-pages.md 3.3; behavior of the Swift App Store in
// CmuxNextApps/Store). It fills an app screen or a narrow tab: the grid adapts its columns, the
// detail keeps a readable width, split stacks below 640 px. State lives in `AppsStore`.
import { useSyncExternalStore, type KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import { AppDetailView } from "./AppDetailView";
import { InstalledView } from "./InstalledView";
import { categoryLabel, isRemovable, TierLabel } from "./model";
import { AppIcon, Badge } from "./parts";
import type { AppsSnapshot, AppsStore } from "./store";
import type { CatalogApp } from "./types";

export function AppsPage({ store, strings }: { store: AppsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const { t } = strings;
  return (
    <div className="apps-page">
      <header className="apps-toolbar">
        <div className="apps-toolbar-title">
          <span className="apps-eyebrow">{t("store.tab.discover")}</span>
          <h1>{t("store.window.title")}</h1>
        </div>
        <div className="apps-tabs" role="tablist">
          {(["discover", "installed"] as const).map((tab) => (
            <button
              key={tab}
              type="button"
              role="tab"
              aria-selected={snap.tab === tab}
              className={`apps-tab${snap.tab === tab ? " selected" : ""}`}
              onClick={() => store.setTab(tab)}
            >
              {t(tab === "discover" ? "store.tab.discover" : "store.tab.installed")}
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
      <div className="apps-discover-intro">
        <div>
          <span className="apps-eyebrow">{t("store.tab.discover")}</span>
          <h2>{t("store.category.all")}</h2>
        </div>
        <span className="apps-discover-rule" aria-hidden="true" />
      </div>
      <div className="apps-chips">
        <button
          type="button"
          className={`apps-chip${snap.category ? "" : " selected"}`}
          onClick={() => store.setCategory(undefined)}
        >
          {t("store.category.all")}
        </button>
        {snap.categories.map((category) => (
          <button
            key={category}
            type="button"
            className={`apps-chip${snap.category === category ? " selected" : ""}`}
            onClick={() => store.setCategory(category)}
          >
            {categoryLabel(category, t)}
          </button>
        ))}
      </div>
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
                  <AppCard key={app.id} app={app} store={store} strings={strings} featured />
                ))}
              </div>
            </section>
          )}
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
                  <AppCard key={app.id} app={app} store={store} strings={strings} />
                ) : (
                  <AppRow
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

function InstallButton({ app, store, strings }: { app: CatalogApp; store: AppsStore; strings: Strings }) {
  // A first-party app ships with cmux: it is hidden or shown, never removed (FIRST-PARTY-APPS).
  if (app.installed && !isRemovable(app)) {
    return (
      <button
        type="button"
        className="apps-button"
        onClick={(event) => {
          event.stopPropagation();
          void store.setHidden(app.id, !app.hidden);
        }}
      >
        {strings.t(app.hidden ? "store.action.show" : "store.action.hide")}
      </button>
    );
  }
  return (
    <button
      type="button"
      className={`apps-button${app.installed ? "" : " primary"}`}
      onClick={(event) => {
        event.stopPropagation();
        void (app.installed ? store.uninstall(app.id) : store.install(app.id));
      }}
    >
      {strings.t(app.installed ? "store.action.remove" : "store.action.install")}
    </button>
  );
}

function AppCard({
  app,
  store,
  strings,
  featured = false,
}: {
  app: CatalogApp;
  store: AppsStore;
  strings: Strings;
  featured?: boolean;
}) {
  const { t } = strings;
  const descriptionId = `apps-description-${app.id.replace(/[^a-z0-9_-]/gi, "-")}`;
  return (
    <article className={`apps-card${featured ? " featured" : ""}`}>
      <button
        type="button"
        className="apps-card-open"
        onClick={() => void store.select(app.id)}
        aria-label={app.name}
        aria-describedby={descriptionId}
      >
        <AppIcon icon={app.icon} name={app.name} size={44} />
        <span className="apps-card-text">
          <span className="apps-name">{app.name}</span>
          <span className="apps-card-meta">
            <span>{app.publisher}</span>
            {app.publisher_verified && (
              <span className="apps-verified" title={t("store.tier.verified")} aria-label={t("store.tier.verified")}>
                ✓
              </span>
            )}
          </span>
          <span className="apps-description" id={descriptionId}>
            {app.description}
          </span>
        </span>
      </button>
      <footer className="apps-card-footer">
        <Badge text={t(TierLabel[app.tier])} />
        {app.categories[0] && <Badge text={categoryLabel(app.categories[0], t)} />}
        {app.installed && <Badge text={t("store.badge.installed")} />}
        <span className="apps-spacer" />
        <button type="button" className="apps-button apps-button-subtle" onClick={() => void store.select(app.id)}>
          {t("store.detail.preview")}
        </button>
        <InstallButton app={app} store={store} strings={strings} />
      </footer>
    </article>
  );
}

function AppRow({
  app,
  selected,
  store,
  strings,
}: {
  app: CatalogApp;
  selected: boolean;
  store: AppsStore;
  strings: Strings;
}) {
  const { t } = strings;
  return (
    <div className={`apps-row${selected ? " selected" : ""}`}>
      <button type="button" className="apps-row-open" onClick={() => void store.select(app.id)} aria-label={app.name}>
        <AppIcon icon={app.icon} name={app.name} size={28} />
        <span className="apps-row-text">
          <span className="apps-name">{app.name}</span>
          <span className="apps-card-meta">
            <span>{app.publisher}</span>
            {app.publisher_verified && (
              <span className="apps-verified" title={t("store.tier.verified")} aria-label={t("store.tier.verified")}>
                ✓
              </span>
            )}
          </span>
          <span className="apps-description">{app.description}</span>
        </span>
      </button>
      <Badge text={t(TierLabel[app.tier])} />
      <InstallButton app={app} store={store} strings={strings} />
    </div>
  );
}
