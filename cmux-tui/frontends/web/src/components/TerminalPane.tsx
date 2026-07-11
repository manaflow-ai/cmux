import { useCallback, useState } from "react";
import type { CmuxClient, Id } from "cmux/browser";
import { t } from "../i18n";
import type { ScreenView } from "../lib/tree";
import { useAttachedTerminal } from "../hooks/useAttachedTerminal";

interface TerminalPaneProps {
  client: CmuxClient | null;
  screen: ScreenView | null;
  onSelectTab(pane: Id, index: number, surface: Id): void;
}

export function TerminalPane({ client, screen, onSelectTab }: TerminalPaneProps) {
  const [terminalError, setTerminalError] = useState<string | null>(null);
  const reportError = useCallback((error: Error) => setTerminalError(error.message), []);
  const surface = screen?.tab?.kind === "pty" && !screen.tab.dead ? screen.tab.surface : null;
  const terminalRef = useAttachedTerminal({ client, surface, onError: reportError });

  return (
    <section className="terminal-panel" aria-label={t("terminal")}>
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
    </section>
  );
}
