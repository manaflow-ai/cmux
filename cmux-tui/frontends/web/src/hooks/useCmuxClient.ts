import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  CmuxClient,
  CmuxTimeoutError,
  WebSocketTransport,
  type ClientDetachedEvent,
  type ClientInfo,
  type Id,
  type IdentifyResult,
  type NotificationEvent,
  type Tree,
} from "cmux/browser";
import { browserClientName } from "../lib/clientName";
import { reconnectTransition, type ReconnectState } from "../lib/reconnect";
import { activeScreen, treeToViewModel } from "../lib/tree";
import { t } from "../i18n";

export interface ConnectionConfig {
  url: string;
  token?: string;
}

export interface Toast extends NotificationEvent {}

type ConnectionStatus = "idle" | "connecting" | "connected" | "reconnecting" | "error";

interface ConnectionState {
  status: ConnectionStatus;
  client: CmuxClient | null;
  info: IdentifyResult | null;
  tree: Tree | null;
  clients: ClientInfo[];
  error: string | null;
  reconnect: ReconnectState | null;
}

const initialState: ConnectionState = {
  status: "idle",
  client: null,
  info: null,
  tree: null,
  clients: [],
  error: null,
  reconnect: null,
};

export function useCmuxClient() {
  const [config, setConfig] = useState<ConnectionConfig | null>(null);
  const [state, setState] = useState<ConnectionState>(initialState);
  const [unread, setUnread] = useState<Set<Id>>(() => new Set());
  const [toasts, setToasts] = useState<Toast[]>([]);
  const refreshRef = useRef<(() => Promise<void>) | null>(null);
  const localToastId = useRef(-1);

  useEffect(() => {
    if (!config) return;
    let cancelled = false;
    let activeClient: CmuxClient | null = null;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;

    const refresh = async () => {
      if (!activeClient) return;
      const tree = await activeClient.listWorkspaces();
      if (!cancelled) setState((current) => ({ ...current, tree }));
    };
    const refreshClients = async () => {
      if (!activeClient) return;
      const clients = await activeClient.listClients();
      if (!cancelled) setState((current) => ({ ...current, clients }));
    };
    refreshRef.current = refresh;

    const start = async (reconnecting: boolean, previousAttempt = 0): Promise<void> => {
      if (cancelled) return;
      let dropHandled = false;
      let canReconnect = false;
      const transport = new WebSocketTransport(config.url, { authToken: config.token });
      const client = new CmuxClient({ transport });
      activeClient = client;

      const scheduleRetry = () => {
        if (cancelled || dropHandled) return;
        dropHandled = true;
        const step = reconnectTransition({ attempt: previousAttempt, delayMs: 0 }, "retry");
        setState((current) => ({
          ...current,
          status: "reconnecting",
          client: null,
          error: null,
          reconnect: step,
        }));
        retryTimer = setTimeout(() => void start(true, step.attempt), step.delayMs);
      };
      transport.onClose(() => {
        if (canReconnect) scheduleRetry();
      });

      try {
        const info = await client.identify();
        if (info.app !== "cmux-tui") throw new Error(t("wrongApp", { app: info.app }));
        if (info.protocol !== 6) throw new Error(t("wrongProtocol", { protocol: info.protocol }));
        // Presence commands are additive (7c5a9e3e60); a protocol-6 server
        // predating them still serves everything else, so degrade instead of
        // failing the whole connect.
        await client.setClientInfo(browserClientName(), "web").catch(() => undefined);
        const events = await client.subscribe();
        const [tree, clients] = await Promise.all([
          client.listWorkspaces(),
          client.listClients().catch(() => []),
        ]);
        if (cancelled) return;
        canReconnect = true;
        // A successful (re)connect resets the retry baseline so the next drop
        // starts from the first backoff step, not the cap.
        previousAttempt = 0;
        setState({ status: "connected", client, info, tree, clients, error: null, reconnect: null });

        void (async () => {
          for (;;) {
            let event;
            try {
              event = await events.next();
            } catch (error) {
              if (cancelled) return;
              // An idle session simply produces no events within the SDK's
              // per-read timeout; only a real transport failure is a drop.
              if (error instanceof CmuxTimeoutError) continue;
              void client.close();
              scheduleRetry();
              return;
            }
            if (cancelled) return;
            if (event.event === "notification") {
              const notification = event as NotificationEvent;
              setToasts((current) => [...current.slice(-2), notification]);
              if (notification.surface !== null) {
                setUnread((current) => new Set(current).add(notification.surface!));
              }
            }
            if (["tree-changed", "layout-changed", "surface-resized", "surface-exited", "title-changed"].includes(event.event)) {
              await refresh();
            }
            if (event.event === "client-attached" || event.event === "client-changed") {
              await refreshClients();
            }
            if (event.event === "client-detached") {
              const detached = event as ClientDetachedEvent;
              setState((current) => ({
                ...current,
                clients: current.clients.filter((item) => item.client !== detached.client),
              }));
            }
          }
        })();
      } catch (error) {
        client.close();
        if (cancelled) return;
        if (reconnecting) {
          scheduleRetry();
        } else {
          setState({
            status: "error",
            client: null,
            info: null,
            tree: null,
            clients: [],
            error: error instanceof Error ? error.message : String(error),
            reconnect: null,
          });
        }
      }
    };

    setState((current) => ({ ...current, status: "connecting", error: null, reconnect: null }));
    void start(false);
    return () => {
      cancelled = true;
      if (retryTimer !== undefined) clearTimeout(retryTimer);
      refreshRef.current = null;
      void activeClient?.close();
    };
  }, [config]);

  const connect = useCallback((next: ConnectionConfig) => {
    setConfig({ ...next, token: next.token || undefined });
  }, []);

  const runMutation = useCallback(async (mutation: (client: CmuxClient) => Promise<unknown>) => {
    if (!state.client) return false;
    try {
      await mutation(state.client);
      return true;
    } catch (error) {
      const toast: Toast = {
        event: "notification",
        notification: localToastId.current--,
        title: t("commandFailed"),
        body: error instanceof Error ? error.message : String(error),
        level: "error",
        surface: null,
      };
      setToasts((current) => [...current.slice(-2), toast]);
      return false;
    }
  }, [state.client]);

  const selectScreen = useCallback(async (workspaceIndex: number, screenIndex: number, surface: Id | null) => {
    await runMutation(async (client) => {
      await client.selectWorkspace({ index: workspaceIndex });
      await client.selectScreen({ index: screenIndex });
      if (surface !== null) setUnread((current) => {
        const next = new Set(current);
        next.delete(surface);
        return next;
      });
    });
  }, [runMutation]);

  const selectTab = useCallback(async (pane: Id, index: number, surface: Id) => {
    await runMutation(async (client) => {
      await client.selectTab({ pane, index });
      setUnread((current) => {
        const next = new Set(current);
        next.delete(surface);
        return next;
      });
    });
  }, [runMutation]);

  const mutations = useMemo(() => ({
    newWorkspace: () => runMutation((client) => client.newWorkspace()),
    newScreen: (workspace: Id) => runMutation((client) => client.newScreen({ workspace })),
    newTab: (pane: Id) => runMutation((client) => client.newTab({ pane })),
    newBrowserTab: (pane: Id, url: string) => runMutation((client) => client.newBrowserTab(url, { pane })),
    split: (pane: Id, dir: "right" | "down") => runMutation((client) => client.split(pane, dir)),
    focusPane: (pane: Id) => runMutation((client) => client.focusPane(pane)),
    closeWorkspace: (workspace: Id) => runMutation((client) => client.closeWorkspace(workspace)),
    closeScreen: (screen: Id) => runMutation((client) => client.closeScreen(screen)),
    closePane: (pane: Id) => runMutation((client) => client.closePane(pane)),
    closeSurface: (surface: Id) => runMutation((client) => client.closeSurface(surface)),
    renameWorkspace: (workspace: Id, name: string) => runMutation((client) => client.renameWorkspace(workspace, name)),
    renameScreen: (screen: Id, name: string) => runMutation((client) => client.renameScreen(screen, name)),
    renamePane: (pane: Id, name: string) => runMutation((client) => client.renamePane(pane, name)),
    renameSurface: (surface: Id, name: string) => runMutation((client) => client.renameSurface(surface, name)),
    zoomPane: (pane: Id) => runMutation((client) => client.zoomPane({ pane, mode: "toggle" })),
    swapPane: (pane: Id, dir: "left" | "right" | "up" | "down") =>
      runMutation((client) => client.swapPane({ pane, dir })),
    setRatio: (pane: Id, dir: "right" | "down", ratio: number) =>
      runMutation((client) => client.setRatio(pane, dir, ratio)),
    detachClient: (clientId: Id) => runMutation(async (client) => {
      await client.detachClient(clientId);
      setState((current) => ({
        ...current,
        clients: current.clients.filter((item) => item.client !== clientId),
      }));
    }),
  }), [runMutation]);

  const refreshClients = useCallback(() => runMutation(async (client) => {
    const clients = await client.listClients();
    setState((current) => ({ ...current, clients }));
  }), [runMutation]);

  const dismissToast = useCallback((notification: Id) => {
    setToasts((current) => current.filter((toast) => toast.notification !== notification));
  }, []);

  const view = useMemo(() => state.tree ? treeToViewModel(state.tree, unread) : [], [state.tree, unread]);
  return {
    ...state,
    view,
    active: activeScreen(view),
    toasts,
    connect,
    selectScreen,
    selectTab,
    mutations,
    refreshClients,
    dismissToast,
  };
}
