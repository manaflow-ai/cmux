// A listing's page: header (icon, name, publisher, tier, state, Open and the item action),
// description, then the shared detail sections (items.tsx): screenshots (the live preview comes
// later with a web scene renderer; coordinator Q6), what it adds, permissions with reasons (grant
// switches once installed), settings once installed, versions, repository. A deployed app also says
// which kinds of machine its server runs on ("Runs on").
import type { Strings } from "../shared/i18n";
import { GrantsPanel } from "./GrantsPanel";
import { AddsList, DetailSection, ItemAction, ItemSettings, ScreenshotStrip, StateBadge } from "./items";
import { orderScopes, RiskLabel, TierLabel } from "./model";
import { AppIcon, Badge } from "./parts";
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
  const { t, format } = strings;
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
  const grants = snap.grants[detail.id];
  return (
    <div className="apps-detail">
      <div className="apps-detail-body">
        {back}
        <header className="apps-detail-header">
          <AppIcon icon={detail.icon} name={detail.name} size={64} />
          <div className="apps-detail-title">
            <h1 className="apps-detail-name">{detail.name}</h1>
            <div className="apps-detail-meta">
              <span>{format("store.detail.publisher", detail.publisher)}</span>
              <Badge text={t(TierLabel[detail.tier])} />
              <StateBadge app={detail} strings={strings} />
            </div>
          </div>
          <div className="apps-detail-actions">
            {detail.installed && (
              <button type="button" className="apps-button" onClick={() => void store.open(detail.id)}>
                {t("store.action.open")}
              </button>
            )}
            <ItemAction app={detail} store={store} strings={strings} />
          </div>
        </header>
        <p className="apps-detail-description selectable">{detail.description}</p>
        <ScreenshotStrip screenshots={detail.screenshots} strings={strings} />
        <AddsList contributes={detail.contributes} strings={strings} />
        {detail.deploy && detail.deploy.targets.length > 0 && (
          <DetailSection title={t("store.detail.runsOn")}>
            <ul className="apps-deploy-targets">
              {detail.deploy.targets.map((target) => (
                <li key={target}>
                  <span>{targetLabel(target, strings)}</span> <code className="apps-muted">{target}</code>
                </li>
              ))}
            </ul>
          </DetailSection>
        )}
        <DetailSection title={t("store.detail.permissions")}>
          {detail.scopes.length === 0 ? (
            <p className="apps-muted">{t("store.detail.noPermissions")}</p>
          ) : grants ? (
            <GrantsPanel grants={grants} store={store} strings={strings} />
          ) : (
            <ul className="apps-scopes">
              {orderScopes(detail.scopes).map((scope) => (
                <li key={scope.scope} className="apps-scope">
                  <code>{scope.scope}</code>
                  {scope.risk !== "standard" && <Badge text={t(RiskLabel[scope.risk])} />}
                  {scope.optional && <Badge text={t("store.detail.optional")} />}
                  <span className="apps-muted selectable">{scope.reason}</span>
                </li>
              ))}
            </ul>
          )}
        </DetailSection>
        <ItemSettings app={detail} store={store} strings={strings} />
        <DetailSection title={t("store.detail.versions")}>
          <ul className="apps-versions">
            {detail.versions.map((version) => (
              <li key={version.version}>
                <span className="apps-version">{version.version}</span>
                <span className="apps-muted">{format("store.detail.requires", version.engines)}</span>
              </li>
            ))}
          </ul>
        </DetailSection>
        {detail.repository?.startsWith("https://") && (
          <a className="apps-link" href={detail.repository} target="_blank" rel="noreferrer">
            {t("store.action.repository")} ↗
          </a>
        )}
      </div>
    </div>
  );
}
