import type { Strings } from "../shared/i18n";
import { AppIcon, Badge } from "./parts";
import type { AppsSnapshot, AppsStore } from "./store";

/** The supervisor-owned update queue shown above the installed rows. */
export function UpdatesView({ snap, store, strings }: { snap: AppsSnapshot; store: AppsStore; strings: Strings }) {
  const { t } = strings;
  const installedById = new Map(snap.installed.map((app) => [app.id, app]));
  const updates = snap.updates.filter((update) => installedById.has(update.app));

  return (
    <section className="apps-section apps-updates" aria-labelledby="apps-updates-heading">
      <div className="apps-installed-head">
        <div className="apps-installed-text">
          <h2 id="apps-updates-heading">{t("store.updates.title")}</h2>
          {snap.updatesLoading && updates.length === 0 ? (
            <span className="apps-muted">{t("store.updates.loading")}</span>
          ) : updates.length > 0 ? (
            <span className="apps-muted">{strings.format("store.updates.available", String(updates.length))}</span>
          ) : snap.updatesError ? null : (
            <span className="apps-muted">{t("store.updates.empty")}</span>
          )}
        </div>
        <button
          type="button"
          className="apps-button"
          onClick={() => void store.refreshUpdates()}
          disabled={snap.updatesLoading}
        >
          {t("store.action.checkUpdates")}
        </button>
      </div>
      {snap.updatesError && (
        <output className="apps-updates-status">
          <span className="apps-failure selectable">
            {snap.updatesStale ? t("store.updates.stale") : snap.updatesError}
          </span>
          <button type="button" className="apps-button" onClick={() => void store.refreshUpdates()}>
            {t("store.action.retry")}
          </button>
        </output>
      )}
      {updates.length > 0 && (
        <div className="apps-updates-list">
          {updates.map((update) => {
            const app = installedById.get(update.app);
            if (!app) return null;
            return (
              <div key={update.app} className="apps-installed-row" data-app-update={update.app}>
                <div className="apps-installed-head">
                  <AppIcon icon={app.icon} name={app.name} size={32} />
                  <div className="apps-installed-text">
                    <span className="apps-name">
                      {app.name} <Badge text={t("store.badge.updateAvailable")} />
                    </span>
                    <span className="apps-muted">
                      {strings.format("store.updates.version", `${app.version} → ${update.version}`)}
                    </span>
                    {update.failure && <span className="apps-failure selectable">{update.failure}</span>}
                  </div>
                  <button type="button" className="apps-button primary" onClick={() => void store.update(update.app)}>
                    {t("store.action.update")}
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
