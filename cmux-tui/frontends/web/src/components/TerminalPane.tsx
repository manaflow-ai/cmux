import { useCallback, useState } from "react";
import type { CmuxClient, Id } from "cmux/browser";
import { t } from "../i18n";
import type { ScreenView } from "../lib/tree";
import { useAttachedTerminal } from "../hooks/useAttachedTerminal";
import { ExtraKeysBar } from "./ExtraKeysBar";

interface TerminalPaneProps {
  client: CmuxClient | null;
  screen: ScreenView | null;
  onSelectTab(pane: Id, index: number, surface: Id): void;
}

export function TerminalPane({ client, screen, onSelectTab }: TerminalPaneProps) {
  // Errors are keyed to the attachment they came from, so a stale alert never
  // overlays a healthy terminal after a reconnect (new client) or tab switch.
  const [errorState, setErrorState] = useState<{
    client: CmuxClient | null;
    surface: Id | null;
    message: string;
  } | null>(null);
  const surface = screen?.tab?.kind === "pty" && !screen.tab.dead ? screen.tab.surface : null;
  const reportError = useCallback(
    (error: Error) => setErrorState({ client, surface, message: error.message }),
    [client, surface],
  );
  const { terminalRef, focused } = useAttachedTerminal({ client, surface, onError: reportError });
  const terminalError =
    errorState !== null && errorState.client === client && errorState.surface === surface
      ? errorState.message
      : null;

  return (
    <section className={`terminal-panel${focused ? " terminal-focused" : ""}`} aria-label={t("terminal")}>
      <div className="tab-bar">
        {screen?.pane?.tabs.map((tab, index) => (
          <button
            className={screen.pane?.active_tab === index ? "active" : ""}
            key={tab.surface}
            onClick={() => onSelectTab(screen.pane!.id, index, tab.surface)}
            type="button"
          >
            <span aria-hidden="true">●</span>{tab.name || tab.title || t("tab", { number: index + 1 })}
          </button>
        ))}
      </div>
      <div className="terminal-stage">
        {surface !== null && <div className="terminal-host" ref={terminalRef} />}
        {!screen?.tab && <div className="terminal-empty">{t("noSurface")}</div>}
        {screen?.tab?.kind === "browser" && <div className="terminal-empty">{t("browserSurface")}</div>}
        {terminalError && <div className="terminal-error" role="alert">{terminalError}</div>}
      </div>
      <ExtraKeysBar
        visible={focused && client !== null && surface !== null}
        onSend={(text) => {
          if (client !== null && surface !== null) void client.send(surface, { text }).catch(reportError);
        }}
      />
    </section>
  );
}
