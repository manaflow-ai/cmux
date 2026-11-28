// A listing's page, modeled on the Mac App Store and the cmux App Store mocks: a header (the big
// icon, the name, the one-line tagline, "publisher · category · Free", and Open plus the one-click
// action on the right), the screenshots, the description, and the app's facts: where it shows up,
// its permissions in plain words (grant switches once installed), its settings once installed, and
// its information (developer, category, version, repository). A deployed app also says which kinds
// of machine its server runs on ("Runs on"). `listing=` lays the same parts out three ways
// (model.ts ListingStyle): a carousel with the facts in a column on its right (the default), a
// stacked page, or one compact column.
import type { Strings } from "../shared/i18n";
import { GrantsPanel } from "./GrantsPanel";
import {
  DetailSection,
  InfoFacts,
  ItemAction,
  ItemSettings,
  PermissionList,
  ScreenshotCarousel,
  ScreenshotStrip,
  ShowsUpIn,
  StateBadge,
} from "./items";
import { categoryLabel } from "./model";
import { AppIcon } from "./parts";
import type { AppsSnapshot, AppsStore } from "./store";

/** The person's words for a manifest deploy target; an unknown kind shows as its name. */
export function targetLabel(target: string, { t }: Strings): string {
  const key = DEPLOY_TARGET_LABELS[target];
  return key ? t(key) : target;
}

const DEPLOY_TARGET_LABELS: Record<string, string> = {
  "self-hosted": "store.deploy.target.selfHosted",
  "cloud-vm": "store.deploy.target.cloudVM",
  "team-vm": "store.deploy.target.teamVM",
  local: "store.deploy.target.local",
};

export function AppDetailView({
  snap,
  store,
  strings,
  showsBack,
}: {
  snap: AppsSnapshot;
  store: AppsStore;
  strings: Strings;
  showsBack?: boolean;
}) {
  const { t } = strings;
  const detail = snap.detail?.id === snap.selection ? snap.detail : undefined;
  const back = showsBack && (
    <button type="button" className="apps-back" onClick={() => void store.select(undefined)}>
      ‹ {t("store.tab.discover")}
    </button>
  );
  const backAction = back || (
    <button type="button" className="apps-back" onClick={() => void store.select(undefined)}>
      ‹ {t("store.tab.discover")}
    </button>
  );
  if (!detail) {
    const state = snap.detailStatus;
    if (state === "loading") {
      return (
        <div className="apps-detail apps-detail-state" data-detail-state="loading">
          <div className="apps-detail-body">
            {backAction}
            <output className="apps-state" aria-busy="true">
              <span className="apps-state-mark" aria-hidden="true">
                …
              </span>
              <strong>{t("store.detail.loading")}</strong>
            </output>
          </div>
        </div>
      );
    }
    if (state === "not-found" || state === "error") {
      return (
        <div className="apps-detail apps-detail-state" data-detail-state={state}>
          <div className="apps-detail-body">
            {backAction}
            <output className="apps-state apps-state-error" role="alert">
              <span className="apps-state-mark" aria-hidden="true">
                !
              </span>
              <strong>{state === "not-found" ? t("store.detail.notFound") : t("store.error.load")}</strong>
              {snap.detailError && <span className="selectable">{snap.detailError}</span>}
              <span className="apps-detail-state-actions">
                <button type="button" className="apps-button" onClick={() => void store.retryDetail()}>
                  {t("store.action.reload")}
                </button>
              </span>
            </output>
          </div>
        </div>
      );
    }
    return <div className="apps-detail">{back}</div>;
  }
  const style = snap.listing;
  const grants = snap.grants[detail.id];
  const shots = detail.screenshotImages ?? [];
  const iconSize = style === "compact" ? 64 : style === "stacked" ? 112 : 96;
  const header = (
    <header className="apps-listing-header">
      <AppIcon icon={detail.icon} name={detail.name} size={iconSize} />
      <div className="apps-listing-title">
        <h1 className="apps-listing-name">{detail.name}</h1>
        {detail.tagline && <p className="apps-listing-tagline">{detail.tagline}</p>}
        <div className="apps-listing-meta">
          <span className="apps-listing-publisher">
            {detail.publisher_verified && (
              <span className="apps-verified" title={t("store.tier.verified")} aria-hidden="true">
                ✓
              </span>
            )}
            {detail.publisher}
          </span>
          {detail.categories[0] && <span>{categoryLabel(detail.categories[0], t)}</span>}
          <span>{t("store.detail.free")}</span>
          <StateBadge app={detail} strings={strings} />
        </div>
      </div>
      <div className="apps-listing-actions">
        {detail.installed && (
          <button
            type="button"
            className="apps-button"
            data-listing-action="open"
            onClick={() => void store.open(detail.id)}
          >
            {t("store.action.open")}
          </button>
        )}
        <ItemAction app={detail} store={store} strings={strings} />
      </div>
    </header>
  );
  const description = detail.description && <p className="apps-listing-description selectable">{detail.description}</p>;
  const runsOn = detail.deploy && detail.deploy.targets.length > 0 && (
    <DetailSection title={t("store.detail.runsOn")}>
      <ul className="apps-deploy-targets">
        {detail.deploy.targets.map((target) => (
          <li key={target}>{targetLabel(target, strings)}</li>
        ))}
      </ul>
    </DetailSection>
  );
  // Once installed, the permissions are switches; before, the plain list of what it asks for.
  const permissions = grants ? (
    <DetailSection title={t("store.detail.permissions")} section="permissions">
      <GrantsPanel grants={grants} store={store} strings={strings} />
    </DetailSection>
  ) : (
    <PermissionList scopes={detail.scopes} strings={strings} />
  );
  const settings = <ItemSettings app={detail} store={store} strings={strings} />;
  const showsUpIn = <ShowsUpIn contributes={detail.contributes} strings={strings} />;
  const info = <InfoFacts detail={detail} strings={strings} />;
  return (
    <div className="apps-detail" data-listing-style={style}>
      <div className={`apps-detail-body apps-listing ${style}`}>
        {back}
        {header}
        {style === "carousel" ? (
          <div className="apps-listing-columns">
            <div className="apps-listing-main">
              {description}
              <ScreenshotCarousel key={detail.id} screenshots={shots} strings={strings} />
              {runsOn}
              {grants && permissions}
              {settings}
            </div>
            <aside className="apps-listing-aside">
              {showsUpIn}
              {!grants && permissions}
              {info}
            </aside>
          </div>
        ) : style === "stacked" ? (
          <>
            <ScreenshotStrip screenshots={shots} strings={strings} />
            {description}
            <div className="apps-listing-grid">
              {showsUpIn}
              {permissions}
              {info}
            </div>
            {runsOn}
            {settings}
          </>
        ) : (
          <>
            {description}
            <ScreenshotCarousel key={detail.id} screenshots={shots} strings={strings} />
            {showsUpIn}
            {permissions}
            {runsOn}
            {settings}
            {info}
          </>
        )}
      </div>
    </div>
  );
}
