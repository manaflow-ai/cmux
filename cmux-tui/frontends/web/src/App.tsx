import { useReducer } from "react";
import "@xterm/xterm/css/xterm.css";
import { ConnectScreen } from "./components/ConnectScreen";
import { ClientsIndicator } from "./components/ClientsIndicator";
import { Sidebar } from "./components/Sidebar";
import { StatusBar } from "./components/StatusBar";
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
  const activeWorkspace = connection.view.find((workspace) => workspace.active) ?? null;
  if (!hasSession) {
    return (
      <ConnectScreen
        connecting={connection.status === "connecting"}
        error={connection.error}
        pairing={connection.pairing}
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
        <span className="mobile-title">{connection.active?.label || t("terminal")}</span>
        <ClientsIndicator
          clients={connection.clients}
          onRefresh={connection.refreshClients}
          onDetach={connection.mutations.detachClient}
        />
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
        onSelect={(...args) => {
          dispatchDrawer("select");
          connection.selectScreen(...args);
        }}
        onNewWorkspace={connection.mutations.newWorkspace}
        onNewScreen={connection.mutations.newScreen}
        onCloseWorkspace={connection.mutations.closeWorkspace}
        onRenameWorkspace={connection.mutations.renameWorkspace}
      />
      <TerminalPane
        client={connection.client}
        clients={connection.clients}
        screen={connection.active}
        onRefreshClients={connection.refreshClients}
        onSetClientSizing={connection.mutations.setClientSizing}
        onUseOnlyClientSizing={connection.mutations.useOnlyClientSizing}
        onUseAllClientSizing={connection.mutations.useAllClientSizing}
        onDetachClient={connection.mutations.detachClient}
        onSelectTab={connection.selectTab}
        onNewTab={connection.mutations.newTab}
        onSplit={connection.mutations.split}
        onSetSplitRatio={connection.mutations.setSplitRatio}
        onSelectPane={connection.selectPane}
        onZoomPane={connection.mutations.zoomPane}
        onClosePane={connection.mutations.closePane}
        onCloseSurface={connection.mutations.closeSurface}
        onRenamePane={connection.mutations.renamePane}
        onRenameSurface={connection.mutations.renameSurface}
      />
      <StatusBar
        workspace={activeWorkspace}
        session={connection.info?.session ?? null}
        onSelectScreen={connection.selectScreen}
        onNewScreen={connection.mutations.newScreen}
        onCloseScreen={connection.mutations.closeScreen}
        onRenameScreen={connection.mutations.renameScreen}
      />
      <Toasts toasts={connection.toasts} onDismiss={connection.dismissToast} />
    </main>
  );
}
