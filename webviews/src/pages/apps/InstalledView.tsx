// Installed: every installed app with Enabled, Update, Permissions, Logs, Hide/Show and Remove (Swift
// AppInstalledView); first-party apps have no Remove (FIRST-PARTY-APPS). Logs show the owner's last lines.
import type { Strings } from "../shared/i18n";
import { GrantsPanel } from "./GrantsPanel";
import { isRemovable } from "./model";
import { AppIcon, Badge, Switch } from "./parts";
import type { AppsSnapshot, AppsStore } from "./store";
import { UpdatesView } from "./UpdatesView";

export function InstalledView({ snap, store, strings }: { snap: AppsSnapshot; store: AppsStore; strings: Strings }) {
  const { t, format } = strings;
  if (snap.installed.length === 0)
    return <div className="apps-empty">{snap.loading ? "" : t("store.empty.noneInstalled")}</div>;
  return (
    <div className="apps-scroll">
      <div className="apps-installed">
        <UpdatesView snap={snap} store={store} strings={strings} />
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
                  <span className={app.failure ? "apps-failure selectable" : "apps-muted"}>
                    {app.failure ?? app.id}
                  </span>
                  {app.instance && (
                    <span className="apps-instance selectable" data-instance-state={app.instance.state}>
                      {format(
                        app.instance.state === "running" ? "store.instance.running" : "store.instance.deploying",
                        app.instance.target,
                      )}
                    </span>
                  )}
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
                  {/* Every app hides and shows (Swift AppInstalledView); only a removable one also has Remove. */}
                  <button
                    type="button"
                    className="apps-button"
                    onClick={() => void store.setHidden(app.id, !app.hidden)}
                  >
                    {t(app.hidden ? "store.action.show" : "store.action.hide")}
                  </button>
                  {isRemovable(app) && (
                    <button type="button" className="apps-button" onClick={() => void store.uninstall(app.id)}>
                      {t("store.action.remove")}
                    </button>
                  )}
                </div>
              </div>
              {snap.grantsShown === app.id && grants && <GrantsPanel grants={grants} store={store} strings={strings} />}
              {snap.logsShown === app.id && (
                <pre className="apps-logs selectable">
                  {logs.length === 0
                    ? t("store.detail.noLogs")
                    : logs.map((line) => (
                        <span
                          key={`${line.at_ms}-${line.level}-${line.message}`}
                          className={line.level === "error" ? "apps-failure" : undefined}
                        >
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
