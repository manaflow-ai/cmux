// The App Store's Community tab: community extensions and setups from the public registry
// (community.ts). The list has kind chips and a sort menu next to them, and the toolbar's search
// filters it. Each row shows its downloads and when it was last updated. A row's page shows the
// README, rendered as React elements, never as HTML (GitHubMarkdown). Items from the person's other
// devices come first with Install on This Mac. Installing always goes through the host's consent
// card. An empty or unreachable registry shows a calm empty state that links to the website.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { GitHubMarkdown } from "../github/GitHubMarkdown";
import { Select } from "../../ui/Select";
import {
  COMMUNITY_SITE,
  COMMUNITY_SORTS,
  type CommunityElsewhere,
  type CommunityKind,
  type CommunityRow,
  type CommunitySnapshot,
  type CommunitySort,
  type CommunityStore,
} from "./community";
import { DetailSection } from "./items";
import { AppIcon, Badge } from "./parts";
import "./community.css";

const idle = (): (() => void) => () => {};
const none = (): CommunitySnapshot | undefined => undefined;

/** The Community store's snapshot, or undefined when the page has none (an older host). */
export function useCommunity(store: CommunityStore | undefined): CommunitySnapshot | undefined {
  return useSyncExternalStore(store?.subscribe ?? idle, store?.getSnapshot ?? none, store?.getSnapshot ?? none);
}

/** Links in a README and on a page open in a new tab, as the store's Repository link does. */
function openLink(url: string): void {
  window.open(url, "_blank", "noopener,noreferrer");
}

const SORT_LABELS: Record<CommunitySort, string> = {
  featured: "store.browse.featured",
  downloads: "store.community.sort.downloads",
  updated: "store.community.sort.updated",
  stars: "store.community.sort.stars",
  name: "store.community.sort.name",
};

/** A kind's name on a row; undefined for a kind the page does not name (it shows no tag). */
function kindLabel(kind: string, { t }: Strings): string | undefined {
  const key = KIND_LABELS[kind];
  return key ? t(key) : undefined;
}

const KIND_LABELS: Record<string, string> = {
  extension: "store.community.kind.extension",
  setup: "store.community.kind.setup",
  theme: "store.community.kind.theme",
  snippet: "store.community.kind.snippet",
};

const KIND_FILTER_LABELS: Record<CommunityKind, string> = {
  extension: "store.community.kind.extensions",
  setup: "store.community.kind.setups",
  theme: "store.community.kind.themes",
  snippet: "store.community.kind.snippets",
};

/** `12,400 downloads` in the page's language. */
export function downloadsText(downloads: number, strings: Strings): string {
  return strings.format("store.community.downloadCount", new Intl.NumberFormat(strings.language).format(downloads));
}

/** The date part of an ISO 8601 time in the page's language; undefined when it does not parse. */
export function dateText(iso: string | undefined, strings: Strings): string | undefined {
  if (!iso) return undefined;
  const time = Date.parse(iso);
  if (Number.isNaN(time)) return undefined;
  return new Intl.DateTimeFormat(strings.language, { dateStyle: "medium", timeZone: "UTC" }).format(time);
}

export function CommunityView({
  snap,
  store,
  strings,
}: {
  snap: CommunitySnapshot;
  store: CommunityStore;
  strings: Strings;
}) {
  if (snap.selection) return <CommunityDetailView snap={snap} store={store} strings={strings} />;
  return (
    <div className="apps-scroll">
      <div className="apps-discover-list apps-community" data-store-section="community">
        <CommunityList snap={snap} store={store} strings={strings} />
      </div>
    </div>
  );
}

function CommunityList({ snap, store, strings }: { snap: CommunitySnapshot; store: CommunityStore; strings: Strings }) {
  const { t } = strings;
  const filtered = !!snap.query.trim() || !!snap.kind;
  const filters = (
    <div className="apps-community-filters">
      <div className="apps-chips" data-store-section="community-kinds">
        <button
          type="button"
          className={`apps-chip${snap.kind ? "" : " selected"}`}
          aria-pressed={!snap.kind}
          onClick={() => store.setKind(undefined)}
        >
          {t("store.category.all")}
        </button>
        {snap.kinds.map((kind) => (
          <button
            key={kind}
            type="button"
            className={`apps-chip${snap.kind === kind ? " selected" : ""}`}
            aria-pressed={snap.kind === kind}
            data-community-kind={kind}
            onClick={() => store.setKind(kind)}
          >
            {strings.t(KIND_FILTER_LABELS[kind])}
          </button>
        ))}
      </div>
      <Select
        className="apps-community-sort"
        label={t("store.community.sortBy")}
        value={snap.sort}
        closeOnPick
        align="end"
        options={COMMUNITY_SORTS.map((sort) => ({ value: sort, label: t(SORT_LABELS[sort]) }))}
        onChange={(value) => store.setSort(value as CommunitySort)}
      />
    </div>
  );
  if (snap.status !== "ready") {
    return (
      <output className="apps-state" aria-busy="true" data-community-state="loading">
        <strong>{t("store.detail.loading")}</strong>
      </output>
    );
  }
  const empty = snap.rows.length === 0;
  return (
    <>
      {snap.elsewhere.length > 0 && <Elsewhere items={snap.elsewhere} snap={snap} store={store} strings={strings} />}
      {(!empty || filtered) && filters}
      {snap.refreshing && (
        <output className="apps-notice" data-community-state="refreshing">
          {t("store.community.updating")}
        </output>
      )}
      {empty && !filtered ? (
        <CommunityEmpty strings={strings} />
      ) : empty ? (
        <output className="apps-state apps-state-empty" data-community-state="no-matches">
          <span className="apps-state-mark" aria-hidden="true">
            ⌕
          </span>
          <strong>{t("store.empty.noMatches")}</strong>
        </output>
      ) : (
        <section className="apps-catalog-section" aria-label={t("store.tab.community")}>
          <div className="apps-list">
            {snap.rows.map((row) => (
              <CommunityListRow key={row.ref} row={row} snap={snap} store={store} strings={strings} />
            ))}
          </div>
        </section>
      )}
    </>
  );
}

/** The registry has nothing yet (empty, not deployed, unreachable): a calm note and the website. */
export function CommunityEmpty({ strings }: { strings: Strings }) {
  const { t } = strings;
  return (
    <div className="apps-state apps-community-empty" data-community-state="empty">
      <span className="apps-state-mark" aria-hidden="true">
        ◇
      </span>
      <strong>{t("store.community.empty.title")}</strong>
      <span>{t("store.community.empty.body")}</span>
      <a className="apps-link" href={COMMUNITY_SITE} target="_blank" rel="noreferrer">
        {t("store.community.empty.link")} ↗
      </a>
    </div>
  );
}

function InstallButton({
  installApp,
  installed,
  label,
  snap,
  store,
  strings,
}: {
  installApp: string;
  installed: boolean;
  label: string;
  snap: CommunitySnapshot;
  store: CommunityStore;
  strings: Strings;
}) {
  if (installed) return <Badge text={strings.t("store.badge.installed")} />;
  const busy = snap.installing.includes(installApp);
  return (
    <button
      type="button"
      className="apps-button primary"
      data-community-action="install"
      data-install-app={installApp}
      disabled={busy}
      aria-busy={busy || undefined}
      onClick={(event) => {
        event.stopPropagation();
        void store.install(installApp);
      }}
    >
      {label}
    </button>
  );
}

function Elsewhere({
  items,
  snap,
  store,
  strings,
}: {
  items: readonly CommunityElsewhere[];
  snap: CommunitySnapshot;
  store: CommunityStore;
  strings: Strings;
}) {
  const { t } = strings;
  return (
    <section className="apps-catalog-section" data-store-section="on-other-devices" aria-labelledby="apps-elsewhere">
      <div className="apps-section-heading">
        <h3 id="apps-elsewhere">{t("store.community.onOtherDevices")}</h3>
      </div>
      <div className="apps-list">
        {items.map((item) => {
          const name = item.name ?? item.ref;
          return (
            <div
              key={item.install_app}
              className="apps-list-row apps-community-row"
              data-community-elsewhere={item.ref}
            >
              <span className="apps-list-open">
                <AppIcon name={name} size={32} />
                <span className="apps-list-text">
                  <span className="apps-name">{name}</span>
                  <span className="apps-description one-line">
                    {[kindLabel(item.kind, strings), item.tag].filter(Boolean).join(" · ")}
                  </span>
                </span>
              </span>
              <span className="apps-list-action">
                <InstallButton
                  installApp={item.install_app}
                  installed={false}
                  label={t("store.community.installOnThisMac")}
                  snap={snap}
                  store={store}
                  strings={strings}
                />
              </span>
            </div>
          );
        })}
      </div>
    </section>
  );
}

function CommunityListRow({
  row,
  snap,
  store,
  strings,
}: {
  row: CommunityRow;
  snap: CommunitySnapshot;
  store: CommunityStore;
  strings: Strings;
}) {
  const updated = dateText(row.updated_at, strings);
  const kind = kindLabel(row.kind, strings);
  return (
    <div className="apps-list-row apps-community-row" data-community-row={row.ref}>
      <button type="button" className="apps-list-open" onClick={() => void store.select(row.ref)} aria-label={row.name}>
        <AppIcon name={row.name} size={40} />
        <span className="apps-list-text">
          <span className="apps-name">
            {row.name}
            {kind && <span className="apps-tag apps-community-kind">{kind}</span>}
          </span>
          <span className="apps-description one-line">{row.tagline ?? row.description}</span>
          <span className="apps-community-stats">
            <span>{row.author}</span>
            <span data-community-stat="downloads">{downloadsText(row.downloads, strings)}</span>
            {updated && (
              <span data-community-stat="updated">{strings.format("store.community.updatedOn", updated)}</span>
            )}
          </span>
        </span>
      </button>
      <span className="apps-list-action">
        <InstallButton
          installApp={row.install_app}
          installed={row.installed}
          label={strings.t("store.action.install")}
          snap={snap}
          store={store}
          strings={strings}
        />
      </span>
    </div>
  );
}

function CommunityDetailView({
  snap,
  store,
  strings,
}: {
  snap: CommunitySnapshot;
  store: CommunityStore;
  strings: Strings;
}) {
  const { t } = strings;
  // The list's row stands in while the page loads or when the owner has no page for it.
  const row: CommunityRow | undefined =
    snap.detail?.ref === snap.selection ? snap.detail : snap.rows.find((item) => item.ref === snap.selection);
  const detail = snap.detail?.ref === snap.selection ? snap.detail : undefined;
  const back = (
    <button type="button" className="apps-back" onClick={() => void store.select(undefined)}>
      ‹ {t("store.tab.community")}
    </button>
  );
  if (!row) {
    return (
      <div className="apps-scroll">
        <div className="apps-detail-body">
          {back}
          {snap.detailStatus === "loading" ? (
            <output className="apps-state" aria-busy="true" data-community-state="detail-loading">
              <strong>{t("store.detail.loading")}</strong>
            </output>
          ) : (
            <CommunityEmpty strings={strings} />
          )}
        </div>
      </div>
    );
  }
  const updated = dateText(row.updated_at, strings);
  const version = row.version ?? row.latest_release?.version;
  const kind = kindLabel(row.kind, strings);
  const facts: [string, string][] = [
    [t("store.detail.developer"), row.author],
    [t("store.community.downloads"), new Intl.NumberFormat(strings.language).format(row.downloads)],
  ];
  if (updated) facts.push([t("store.community.lastUpdated"), updated]);
  if (version) facts.push([t("store.detail.version"), version]);
  if (detail?.license) facts.push([t("store.community.license"), detail.license]);
  return (
    <div className="apps-scroll">
      <div className="apps-detail-body apps-listing carousel apps-community-detail" data-community-detail={row.ref}>
        {back}
        <header className="apps-listing-header">
          <AppIcon name={row.name} size={96} />
          <div className="apps-listing-title">
            <h1 className="apps-listing-name">{row.name}</h1>
            {row.tagline && <p className="apps-listing-tagline">{row.tagline}</p>}
            <div className="apps-listing-meta">
              <span className="apps-listing-publisher">{row.author}</span>
              {kind && <span>{kind}</span>}
              <span>{downloadsText(row.downloads, strings)}</span>
            </div>
          </div>
          <div className="apps-listing-actions">
            <InstallButton
              installApp={row.install_app}
              installed={row.installed}
              label={t("store.action.install")}
              snap={snap}
              store={store}
              strings={strings}
            />
          </div>
        </header>
        <div className="apps-listing-columns">
          <div className="apps-listing-main">
            {row.description && <p className="apps-listing-description selectable">{row.description}</p>}
            {detail?.readme ? (
              <DetailSection title={t("store.community.readme")} section="readme">
                <div className="apps-community-readme selectable">
                  <GitHubMarkdown source={detail.readme} open={openLink} />
                </div>
              </DetailSection>
            ) : (
              snap.detailStatus === "loading" && (
                <output className="apps-muted" aria-busy="true">
                  {t("store.detail.loading")}
                </output>
              )
            )}
          </div>
          <aside className="apps-listing-aside">
            <DetailSection title={t("store.detail.information")} section="information">
              <dl className="apps-facts">
                {facts.map(([label, value]) => (
                  <div key={label} className="apps-fact">
                    <dt>{label}</dt>
                    <dd>{value}</dd>
                  </div>
                ))}
              </dl>
              {row.repository.startsWith("https://") && (
                <a className="apps-link" href={row.repository} target="_blank" rel="noreferrer">
                  {t("store.action.repository")} ↗
                </a>
              )}
            </DetailSection>
          </aside>
        </div>
      </div>
    </div>
  );
}
