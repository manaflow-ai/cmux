// Discover's Community section (custom-panes-DESIGN.md 6.4): apps people published and a reviewer
// approved, from the Cloud registry (`cmux.registry.listings`). A listing already in the daemon's
// catalog shows that app's state and action; one that is not offers Get, which downloads the
// approved bundle (`cmux.registry.get`) and then installs it through the native scopes sheet.
import type { Strings } from "../shared/i18n";
import { ItemAction, StateBadge } from "./items";
import { matches } from "./model";
import { AppIcon, Badge } from "./parts";
import { NO_REGISTRY, type AppsSnapshot, type AppsStore } from "./store";
import type { CatalogApp, RegistryListing } from "./types";
import { manifestSummary } from "./wire";

/** The listing as a catalog row for the search match (the registry has no categories). */
function asCatalogApp(listing: RegistryListing): CatalogApp {
  return {
    id: listing.app,
    name: listing.name,
    description: listing.description,
    publisher: listing.publisher,
    publisher_verified: false,
    tier: "unverified",
    categories: [],
    latest_version: listing.version,
    install_count: 0,
    installed: false,
  };
}

export function CommunitySection({ snap, store, strings }: { snap: AppsSnapshot; store: AppsStore; strings: Strings }) {
  const { t } = strings;
  const registry = snap.registry ?? NO_REGISTRY;
  const status = registry.listingsStatus;
  // Hidden while the first read runs, on a host without the registry, and under a category filter.
  if (status === "idle" || status === "loading" || status === "unavailable" || snap.category) return null;
  const listings = registry.listings.filter((listing) => matches(asCatalogApp(listing), snap.query));
  if (snap.query.trim() && listings.length === 0) return null;
  const catalog = new Map(snap.catalog.map((app) => [app.id, app]));
  return (
    <section className="apps-catalog-section apps-community" aria-labelledby="apps-community-title">
      <div className="apps-section-heading">
        <h3 id="apps-community-title">{t("store.registry.community")}</h3>
      </div>
      {status === "signed-out" ? (
        <p className="apps-muted apps-community-note">{t("store.registry.signedOut")}</p>
      ) : status === "error" ? (
        <p className="apps-muted apps-community-note" role="alert">
          <strong>{t("store.error.load")}</strong> <span className="selectable">{registry.listingsError}</span>
        </p>
      ) : listings.length === 0 ? (
        <p className="apps-muted apps-community-note">{t("store.registry.empty")}</p>
      ) : (
        <div className="apps-grid">
          {listings.map((listing) => (
            <CommunityCard
              key={listing.app}
              listing={listing}
              local={catalog.get(listing.app)}
              busy={registry.busy}
              store={store}
              strings={strings}
            />
          ))}
        </div>
      )}
    </section>
  );
}

function CommunityCard({
  listing,
  local,
  busy,
  store,
  strings,
}: {
  listing: RegistryListing;
  local?: CatalogApp;
  busy?: string;
  store: AppsStore;
  strings: Strings;
}) {
  const { t, format } = strings;
  const summary = manifestSummary(listing.manifest);
  // An installed copy older than the approved listing gets it again (no update prompts in the MVP).
  const newer = local?.installed && local.latest_version !== listing.version;
  const get = (label: string) => (
    <button
      type="button"
      className="apps-button primary"
      disabled={busy !== undefined}
      aria-busy={busy === listing.app}
      onClick={() => void store.getListing(listing.app, listing.version)}
    >
      {label}
    </button>
  );
  return (
    <article className="apps-card apps-community-card" data-registry-app={listing.app}>
      <div className="apps-card-open apps-community-head">
        <AppIcon icon={summary.symbol ? { symbol: summary.symbol } : undefined} name={listing.name} size={44} />
        <span className="apps-card-text">
          <span className="apps-name">{listing.name}</span>
          <span className="apps-card-meta">
            <span>{listing.publisher}</span>
          </span>
          <span className="apps-description">{listing.description || summary.description}</span>
        </span>
      </div>
      <footer className="apps-card-footer">
        <Badge text={t("store.tier.unverified")} />
        <span className="apps-version">{listing.version}</span>
        {local && <StateBadge app={local} strings={strings} />}
        <span className="apps-card-actions">
          {newer ? (
            get(format("store.registry.getVersion", listing.version))
          ) : local ? (
            <ItemAction app={local} store={store} strings={strings} />
          ) : (
            get(t("store.registry.get"))
          )}
        </span>
      </footer>
    </article>
  );
}
