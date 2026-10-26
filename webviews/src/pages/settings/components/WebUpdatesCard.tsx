// Updates > Web UI (plans/cmux-next/web-ota.md): the web UI a NIGHTLY build serves between app
// updates, from the host lists' `web_updates` (the app's WebUpdates, live through
// cmux.settings.host.changed). Check Now and Roll Back take the paths of the socket's
// updates.web.check and updates.web.rollback. Which updates it takes is the schema row updates.web.
import { useState } from "react";
import { useSettingsState, useStore } from "../context";
import type { WebUpdatesState, WebUpdateVersion } from "../ops";
import { locale, t } from "../strings";
import { ActionRow } from "./ActionRow";

type Run = "check" | "rollback";

function when(seconds: number): string {
  return new Intl.DateTimeFormat(locale(), { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(seconds * 1000),
  );
}

function versionText(version: WebUpdateVersion | null): string {
  if (!version) return t("settingsWindow.webUpdates.builtIn");
  return t("settingsWindow.webUpdates.version", version.commit.slice(0, 7), when(version.committed_at));
}

/** The check in plain words: what runs now, why the last check took nothing, or when it ran. */
function statusText(state: WebUpdatesState): string {
  if (state.phase === "checking") return t("settingsWindow.webUpdates.checking");
  if (state.phase === "downloading") return t("settingsWindow.webUpdates.downloading");
  if (state.phase === "failed") {
    const known = state.refusal === "untrusted" || state.refusal === "damaged" || state.refusal === "offline";
    return t(known ? `settingsWindow.webUpdates.refusal.${state.refusal}` : "settingsWindow.webUpdates.failed");
  }
  if (state.channel === "off") return t("settingsWindow.webUpdates.off");
  if (state.refusal === "app_too_old") return t("settingsWindow.webUpdates.refusal.app_too_old");
  if (state.last_check === null) return t("settingsWindow.webUpdates.notChecked");
  return t("settingsWindow.webUpdates.upToDate", when(state.last_check));
}

function rollBackText(state: WebUpdatesState): string {
  if (!state.active) return t("settingsWindow.webUpdates.rollBack.none");
  if (!state.previous) return t("settingsWindow.webUpdates.rollBack.bundled");
  return t("settingsWindow.webUpdates.rollBack.previous", state.previous.commit.slice(0, 7));
}

export function WebUpdatesCard() {
  const store = useStore();
  const { host } = useSettingsState();
  const [running, setRunning] = useState<Run | null>(null);
  const [failed, setFailed] = useState<Run | null>(null);
  const state = host?.web_updates;
  if (!state) return null;
  const busy = running !== null || state.phase === "checking" || state.phase === "downloading";
  const run = async (action: Run) => {
    setRunning(action);
    setFailed(null);
    const ok = await store.runWebUpdates(action);
    setRunning(null);
    if (!ok) setFailed(action);
  };
  const pending = state.pending && t(`settingsWindow.webUpdates.pending.${state.pending}`);
  return (
    <section className="group" data-card="web-updates" data-phase={state.phase}>
      <h3 className="group-title">{t("settingsWindow.webUpdates.title")}</h3>
      <div className="rows">
        <ActionRow title={t("settingsWindow.webUpdates.served")} help={versionText(state.served)}>
          {null}
        </ActionRow>
        <ActionRow
          title={t("settingsWindow.webUpdates.status")}
          help={[statusText(state), pending].filter(Boolean).join(" ")}
        >
          <button
            type="button"
            className="button"
            data-web-updates="check"
            disabled={busy || state.channel === "off"}
            onClick={() => void run("check")}
          >
            {t("settingsWindow.webUpdates.checkNow")}
          </button>
        </ActionRow>
        <ActionRow title={t("settingsWindow.webUpdates.rollBack")} help={rollBackText(state)}>
          <button
            type="button"
            className="button"
            data-web-updates="rollback"
            disabled={busy || !state.active}
            onClick={() => void run("rollback")}
          >
            {t("settingsWindow.webUpdates.rollBack")}
          </button>
        </ActionRow>
      </div>
      {failed && (
        <output className="notice" data-web-updates-failed={failed}>
          <span className="notice-text">{t(`settingsWindow.webUpdates.${failed}Failed`)}</span>
        </output>
      )}
    </section>
  );
}
