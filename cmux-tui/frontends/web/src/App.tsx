import { useReducer } from "react";
import "@xterm/xterm/css/xterm.css";
import { ConnectScreen } from "./components/ConnectScreen";
import { Sidebar } from "./components/Sidebar";
import { TerminalPane } from "./components/TerminalPane";
import { Toasts } from "./components/Toasts";
import { useCmuxClient } from "./hooks/useCmuxClient";
import { useVisualViewport } from "./hooks/useVisualViewport";
import { t } from "./i18n";
import { drawerReducer } from "./lib/mobile";

export default function App() {
  useVisualViewport();
  const connection = useCmuxClient();
  const [drawer, dispatchDrawer] = useReducer(drawerReducer, "closed");
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
    <main className={`app-shell drawer-${drawer}`}>
      {connection.status === "reconnecting" && connection.reconnect && (
        <div className="reconnect-banner" role="status">
          {t("reconnecting", {
            seconds: Math.max(1, Math.ceil(connection.reconnect.delayMs / 1000)),
            attempt: connection.reconnect.attempt,
          })}
        </div>
      )}
      <header className="mobile-toolbar">
        <button
          type="button"
          aria-label={drawer === "open" ? t("closeWorkspaces") : t("openWorkspaces")}
          aria-expanded={drawer === "open"}
          onClick={() => dispatchDrawer("toggle")}
        >
          <span aria-hidden="true">☰</span>
        </button>
        <span>{connection.active?.label || t("terminal")}</span>
      </header>
      <button
        className="drawer-backdrop"
        type="button"
        aria-label={t("closeWorkspaces")}
        onClick={() => dispatchDrawer("close")}
      />
      <Sidebar
        open={drawer === "open"}
        workspaces={connection.view}
        onClose={() => dispatchDrawer("close")}
        onSelect={async (...args) => {
          dispatchDrawer("select");
          await connection.selectScreen(...args);
        }}
      />
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
