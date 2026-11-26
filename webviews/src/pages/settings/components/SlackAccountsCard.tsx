// Slack is an invariant product name; all connection copy uses the Settings catalog.
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { useSearch } from "@tanstack/react-router";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { stringifySettingsSearch, type SettingsSearch } from "../router";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { BOT_NAME_MAX, SlackConnectionController, type SlackState } from "../slackConnection";
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
      createOwnBot={(name, token) => void controller.createOwnBot(name, token)}
      openTokenPage={() => void controller.openTokenPage()}
      connect={() => void controller.connect()}
      disconnect={() => void controller.disconnect()}
      refresh={() => void controller.refresh()}
    />
  );
}

export type SlackConnectionActions = {
  connect(): void;
  disconnect(): void;
  refresh(): void;
  createOwnBot(name: string, configToken: string): void;
  openTokenPage(): void;
};

/** The Slack card: one "Connect Slack" button, and a second door that makes a bot with the person's own name. */
export function SlackConnectionRow({
  state,
  initialOwnBot = false,
  connect,
  disconnect,
  refresh,
  createOwnBot,
  openTokenPage,
}: { state: SlackState; initialOwnBot?: boolean } & SlackConnectionActions) {
  const [ownBot, setOwnBot] = useState(initialOwnBot);
  const [name, setName] = useState("");
  // The token lives in this field only until it is sent; it is cleared the moment the platform takes it.
  const [token, setToken] = useState("");
  const busy = state.phase === "loading" || state.phase === "connecting" || state.phase === "disconnecting";
  const connected = state.teams.length > 0;
  const waiting = state.phase === "awaiting";
  const form = ownBot && !connected;
  const detail = waiting
    ? t("settingsPage.slack.awaiting")
    : state.phase === "connecting"
      ? t("settingsPage.slack.connecting")
      : state.phase === "loading"
        ? t("settingsPage.slack.loading")
        : connected
          ? state.teams.map((team) => team.name).join(" · ")
          : t("settingsPage.slack.detail");
  useEffect(() => {
    if (waiting) setToken("");
  }, [waiting]);
  return (
    <section className="group" data-card="slack-connection" aria-busy={busy}>
      <h3 className="group-title">Slack</h3>
      <div className="rows">
        <div className="row accounts-row">
          <div className="row-label">
            <output className="row-help">{detail}</output>
            {state.confirmed && <output className="row-help">{t("settingsPage.slack.connected")}</output>}
            {state.error && (
              <div className="row-error" role="alert">
                {t(`settingsPage.slack.${state.error}`)}
              </div>
            )}
          </div>
          <div className="accounts-body">
            <div className="accounts-buttons">
              <Button
                className="button"
                variant={connected || waiting || state.error ? "subtle" : "solid"}
                data-slack-action="primary"
                disabled={busy}
                onClick={waiting || (state.error && !form) ? refresh : connected ? disconnect : connect}
              >
                {waiting || (state.error && !form)
                  ? t("settingsPage.slack.refresh")
                  : connected
                    ? t("settingsPage.slack.disconnect")
                    : t("settingsPage.slack.connect")}
              </Button>
              {!connected && !waiting && (
                <Button
                  className="link-button"
                  variant="ghost"
                  data-slack-action="own-bot"
                  aria-expanded={ownBot}
                  disabled={busy}
                  onClick={() => setOwnBot((open) => !open)}
                >
                  {t("settingsPage.slack.ownBot.toggle")}
                </Button>
              )}
            </div>
          </div>
        </div>
        {form && !waiting && (
          <form
            className="row accounts-form"
            data-slack-form="own-bot"
            onSubmit={(event) => {
              event.preventDefault();
              if (!busy) createOwnBot(name, token);
            }}
          >
            <label className="row-label">
              <span className="row-title">{t("settingsPage.slack.ownBot.name")}</span>
              <Input
                className="field"
                type="text"
                autoComplete="off"
                spellCheck={false}
                maxLength={BOT_NAME_MAX}
                placeholder={"cmux"}
                value={name}
                onChange={(event) => setName(event.target.value)}
              />
            </label>
            <label className="row-label">
              <span className="row-title">{t("settingsPage.slack.ownBot.token")}</span>
              <Input
                className="field"
                type="password"
                autoComplete="off"
                autoCapitalize="off"
                spellCheck={false}
                placeholder="xoxe.xoxp-…"
                value={token}
                onChange={(event) => setToken(event.target.value)}
              />
              <span className="row-help">
                {t("settingsPage.slack.ownBot.tokenHelp")}{" "}
                <Button className="link-button" variant="ghost" size="sm" type="button" onClick={openTokenPage}>
                  api.slack.com/apps
                </Button>
              </span>
            </label>
            <div className="accounts-buttons">
              <Button
                className="button"
                variant="solid"
                type="submit"
                data-slack-action="create"
                disabled={busy || !token}
              >
                {t("settingsPage.slack.ownBot.submit")}
              </Button>
              <Button className="button" type="button" disabled={busy} onClick={() => setOwnBot(false)}>
                {t("settingsPage.cancel")}
              </Button>
            </div>
          </form>
        )}
      </div>
    </section>
  );
}
