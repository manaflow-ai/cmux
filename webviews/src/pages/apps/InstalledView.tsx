// Installed: every installed app with Enabled, Update, Permissions, Logs and Remove (Swift
// AppInstalledView); first-party apps get Hide/Show in place of Remove (FIRST-PARTY-APPS). Logs follow the owner's stream while shown.
import type { Strings } from "../shared/i18n";
import { GrantsPanel } from "./GrantsPanel";
import { isRemovable } from "./model";
import { AppIcon, Badge, Switch } from "./parts";
import type { AppsSnapshot, AppsStore } from "./store";

export function InstalledView({ snap, store, strings }: { snap: AppsSnapshot; store: AppsStore; strings: Strings }) {
  const { t } = strings;
  if (snap.installed.length === 0)
    return <div className="apps-empty">{snap.loading ? "" : t("store.empty.noneInstalled")}</div>;
  return (
    <div className="apps-scroll">
      <div className="apps-installed">
        {snap.installed.map((app) => {
          const grants = snap.grants[app.id];
          const logs = snap.logs[app.id] ?? [];
          return (
            <section key={app.id} className="apps-installed-row">
              <div className="apps-installed-head">
                <AppIcon icon={app.icon} name={app.name} size={32} />
                <div className="apps-installed-text">
                  <span className="apps-name">
                    {app.name} <span className="apps-version">{app.version}</span>
                    {app.source === "local" && <Badge text={t("store.badge.local")} />}
                  </span>
                  <span className={app.failure ? "apps-failure" : "apps-muted"}>{app.failure ?? app.id}</span>
                </div>
                <div className="apps-installed-actions">
                  <Switch
                    on={app.enabled}
                    label={t("store.action.enabled")}
                    onChange={(on) => void store.setEnabled(app.id, on)}
                  />
                  {app.update && (
                    <button type="button" className="apps-button primary" onClick={() => void store.update(app.id)}>
                      {t("store.action.update")}
                    </button>
                  )}
                  <button
                    type="button"
                    className={`apps-button${snap.grantsShown === app.id ? " pressed" : ""}`}
                    aria-pressed={snap.grantsShown === app.id}
                    onClick={() => void store.toggleGrants(app.id)}
                  >
                    {t("store.detail.permissions")}
                  </button>
                  <button
                    type="button"
                    className={`apps-button${snap.logsShown === app.id ? " pressed" : ""}`}
                    aria-pressed={snap.logsShown === app.id}
                    onClick={() => void store.toggleLogs(app.id)}
                  >
                    {t(snap.logsShown === app.id ? "store.action.hideLogs" : "store.action.logs")}
                  </button>
                  {isRemovable(app) ? (
                    <button type="button" className="apps-button" onClick={() => void store.uninstall(app.id)}>
                      {t("store.action.remove")}
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="apps-button"
                      onClick={() => void store.setHidden(app.id, !app.hidden)}
                    >
                      {t(app.hidden ? "store.action.show" : "store.action.hide")}
                    </button>
                  )}
                </div>
              </div>
              {snap.grantsShown === app.id && grants && <GrantsPanel grants={grants} store={store} strings={strings} />}
              {snap.logsShown === app.id && (
                <pre className="apps-logs">
                  {logs.length === 0
                    ? t("store.detail.noLogs")
                    : logs.map((line, index) => (
                        <span key={index} className={line.level === "error" ? "apps-failure" : undefined}>
                          {line.level.padEnd(5)} {line.message}
                          {"\n"}
                        </span>
                      ))}
                </pre>
              )}
            </section>
          );
        })}
      </div>
    </div>
  );
}
