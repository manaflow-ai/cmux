// Slack is an invariant product name; all connection copy uses the Settings catalog.
import { useEffect, useMemo, useRef, useSyncExternalStore } from "react";
import { useSearch } from "@tanstack/react-router";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { stringifySettingsSearch, type SettingsSearch } from "../router";
import { SlackConnectionController, type SlackState } from "../slackConnection";
import { t } from "../strings";

export function SlackAccountsCard() {
  const { accounts } = useSettingsState();
  // Remount for account/team changes so late replies cannot cross identities.
  const scope = JSON.stringify([
    accounts?.cmux.detail,
    accounts?.cmux.statusKind,
    accounts?.teams?.options.find((option) => option.active)?.id,
  ]);
  return <SlackAccountConnection key={scope} />;
}

function SlackAccountConnection() {
  const store = useStore();
  const router = useSettingsRouter();
  const search = useSearch({ strict: false }) as SettingsSearch;
  const consumed = useRef<string | undefined>(undefined);
  const controller = useMemo(() => new SlackConnectionController(store.slackCalls), [store]);
  const state = useSyncExternalStore(controller.subscribe, controller.getSnapshot, controller.getSnapshot);
  useEffect(() => {
    void controller.refresh();
    const focused = () => {
      if (document.visibilityState === "visible") void controller.refresh();
    };
    window.addEventListener("focus", focused);
    document.addEventListener("visibilitychange", focused);
    return () => {
      controller.dispose();
      window.removeEventListener("focus", focused);
      document.removeEventListener("visibilitychange", focused);
    };
  }, [controller, store]);
  useEffect(() => {
    if (!search.slack || !search.open || consumed.current === search.open) return;
    consumed.current = search.open;
    const { slack, open: _open, ...remaining } = search;
    router.history.replace(`/settings/accounts${stringifySettingsSearch(remaining)}`);
    if (slack === "connect") void controller.connect();
    else void controller.refresh(true);
  }, [controller, router, search]);
  return (
    <SlackConnectionRow
      state={state}
      connect={() => void controller.connect()}
      disconnect={() => void controller.disconnect()}
      refresh={() => void controller.refresh()}
    />
  );
}

export function SlackConnectionRow({
  state,
  connect,
  disconnect,
  refresh,
}: {
  state: SlackState;
  connect(): void;
  disconnect(): void;
  refresh(): void;
}) {
  const busy = state.phase === "loading" || state.phase === "connecting" || state.phase === "disconnecting";
  const connected = state.teams.length > 0;
  const detail =
    state.phase === "awaiting"
      ? t("settingsPage.slack.awaiting")
      : state.phase === "connecting"
        ? t("settingsPage.slack.connecting")
        : state.phase === "loading"
          ? t("settingsPage.slack.loading")
          : connected
            ? state.teams.map((team) => team.name).join(" · ")
            : t("settingsPage.slack.detail");
  return (
    <section className="group" data-card="slack-connection" aria-busy={busy}>
      <div className="rows">
        <div className="row">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">Slack</div>
              <output className="row-help">{detail}</output>
              {state.confirmed && <output className="row-help">{t("settingsPage.slack.connected")}</output>}
              {state.error && (
                <div className="row-error" role="alert">
                  {t(`settingsPage.slack.${state.error}`)}
                </div>
              )}
            </div>
            <div className="row-control">
              <button
                type="button"
                className="button"
                disabled={busy}
                onClick={state.phase === "awaiting" || state.error ? refresh : connected ? disconnect : connect}
              >
                {state.phase === "awaiting" || state.error
                  ? t("settingsPage.slack.refresh")
                  : connected
                    ? t("settingsPage.slack.disconnect")
                    : t("settingsPage.slack.connect")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
