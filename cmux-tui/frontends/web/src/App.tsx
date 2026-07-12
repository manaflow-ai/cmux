import "@xterm/xterm/css/xterm.css";
import { ConnectScreen } from "./components/ConnectScreen";
import { Sidebar } from "./components/Sidebar";
import { TerminalPane } from "./components/TerminalPane";
import { Toasts } from "./components/Toasts";
import { useCmuxClient } from "./hooks/useCmuxClient";
import { t } from "./i18n";

export default function App() {
  const connection = useCmuxClient();
  const hasSession = connection.info !== null || connection.tree !== null;
  if (!hasSession) {
    return (
      <ConnectScreen
        connecting={connection.status === "connecting"}
        error={connection.error}
        onConnect={connection.connect}
      />
    );
  }

  return (
    <main className="app-shell">
      {connection.status === "reconnecting" && connection.reconnect && (
        <div className="reconnect-banner" role="status">
          {t("reconnecting", {
            seconds: Math.max(1, Math.ceil(connection.reconnect.delayMs / 1000)),
            attempt: connection.reconnect.attempt,
          })}
        </div>
      )}
      <Sidebar workspaces={connection.view} onSelect={connection.selectScreen} />
      <TerminalPane client={connection.client} screen={connection.active} onSelectTab={connection.selectTab} />
      <footer className="status-bar">
        <span><b>{t("session")}</b> {connection.info?.session ?? "—"}</span>
        <span className={`connection-state ${connection.status}`}><i />{t("connection")}: {connection.status === "connected" ? t("connected") : t("disconnected")}</span>
        <span><b>{t("protocol")}</b> v{connection.info?.protocol ?? "—"}</span>
      </footer>
      <Toasts toasts={connection.toasts} onDismiss={connection.dismissToast} />
    </main>
  );
}
