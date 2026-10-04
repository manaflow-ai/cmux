// A listing's page: header (icon, name, publisher, tier, Install/Remove, Open), description,
// screenshots (the live preview comes later with a web scene renderer; coordinator Q6),
// permissions with reasons (grant switches once installed), versions, repository.
import type { Strings } from "../shared/i18n";
import { GrantsPanel } from "./GrantsPanel";
import { orderScopes, TierLabel } from "./model";
import { AppIcon, Badge } from "./parts";
import type { AppsSnapshot, AppsStore } from "./store";

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
  if (!detail) return <div className="apps-detail">{back}</div>;
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
              {detail.installed && (
                <Badge text={t(detail.enabled === false ? "store.badge.disabled" : "store.badge.installed")} />
              )}
            </div>
          </div>
          <div className="apps-detail-actions">
            {detail.installed && (
              <button type="button" className="apps-button" onClick={() => void store.open(detail.id)}>
                {t("store.action.open")}
              </button>
            )}
            <button
              type="button"
              className={`apps-button${detail.installed ? "" : " primary"}`}
              onClick={() => void (detail.installed ? store.uninstall(detail.id) : store.install(detail.id))}
            >
              {t(detail.installed ? "store.action.remove" : "store.action.install")}
            </button>
          </div>
        </header>
        <p className="apps-detail-description">{detail.description}</p>
        {detail.screenshots.length > 0 && (
          <section className="apps-section">
            <h2>{t("store.detail.screenshots")}</h2>
            <div className="apps-screenshots">
              {detail.screenshots
                .filter((src) => src.startsWith("data:image/"))
                .map((src, index) => (
                  <img key={index} src={src} alt="" className="apps-screenshot" />
                ))}
            </div>
          </section>
        )}
        <section className="apps-section">
          <h2>{t("store.detail.permissions")}</h2>
          {detail.scopes.length === 0 ? (
            <p className="apps-muted">{t("store.detail.noPermissions")}</p>
          ) : grants ? (
            <GrantsPanel grants={grants} store={store} strings={strings} />
          ) : (
            <ul className="apps-scopes">
              {orderScopes(detail.scopes).map((scope) => (
                <li key={scope.scope} className="apps-scope">
                  <code>{scope.scope}</code>
                  {scope.optional && <Badge text={t("store.detail.optional")} />}
                  <span className="apps-muted">{scope.reason}</span>
                </li>
              ))}
            </ul>
          )}
        </section>
        <section className="apps-section">
          <h2>{t("store.detail.versions")}</h2>
          <ul className="apps-versions">
            {detail.versions.map((version) => (
              <li key={version.version}>
                <span className="apps-version">{version.version}</span>
                <span className="apps-muted">{format("store.detail.requires", version.engines)}</span>
              </li>
            ))}
          </ul>
        </section>
        {detail.repository?.startsWith("https://") && (
          <a className="apps-link" href={detail.repository} target="_blank" rel="noreferrer">
            {t("store.action.repository")} ↗
          </a>
        )}
      </div>
    </div>
  );
}
