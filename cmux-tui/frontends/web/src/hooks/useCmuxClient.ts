import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import {
  CmuxClient,
  CmuxTimeoutError,
  WebSocketTransport,
  type ClientDetachedEvent,
  type ClientInfo,
  type Id,
  type IdentifyResult,
  type NotificationEvent,
  type PairingChallenge,
  type TitleChangedEvent,
  type Tree,
} from "cmux/browser";
import { browserClientName } from "../lib/clientName";
import { createCoalescedRefresh } from "../lib/coalescedRefresh";
import {
  initialLocalSelectionState,
  localSelectionReducer,
  selectionSnapshot,
} from "../lib/localSelection";
import { reconnectTransition, type ReconnectState } from "../lib/reconnect";
import { SUPPORTED_PROTOCOL, supportsProtocol } from "../lib/protocol";
import { activeScreen, locateSurface, SurfaceTitleReconciler, treeToViewModel } from "../lib/tree";
import { t } from "../i18n";

export interface ConnectionConfig {
  url: string;
  token?: string;
}

export interface Toast extends NotificationEvent {}

type ConnectionStatus = "idle" | "connecting" | "pairing" | "connected" | "reconnecting" | "error";

interface ConnectionState {
  status: ConnectionStatus;
  client: CmuxClient | null;
  info: IdentifyResult | null;
  tree: Tree | null;
  clients: ClientInfo[];
  error: string | null;
  reconnect: ReconnectState | null;
  pairing: PairingChallenge | null;
}

const initialState: ConnectionState = {
  status: "idle",
  client: null,
  info: null,
  tree: null,
  clients: [],
  error: null,
  reconnect: null,
  pairing: null,
};

export function useCmuxClient() {
  const [config, setConfig] = useState<ConnectionConfig | null>(null);
  const [state, setState] = useState<ConnectionState>(initialState);
  const [unread, setUnread] = useState<Set<Id>>(() => new Set());
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [selection, dispatchSelection] = useReducer(localSelectionReducer, initialLocalSelectionState);
  const refreshRef = useRef<(() => Promise<Tree | null>) | null>(null);
  const clientsRefreshRef = useRef<(() => void) | null>(null);
  const localToastId = useRef(-1);
  const pairingCredential = useRef<string | undefined>(undefined);

  useEffect(() => {
    if (!config) return;
    let cancelled = false;
    let activeClient: CmuxClient | null = null;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    let titleFlushTimer: ReturnType<typeof setTimeout> | undefined;
    const pendingSurfaceTitles = new Map<Id, string>();
    let titleReconciler = new SurfaceTitleReconciler();
    let clientPresenceGeneration = 0;

    const discardPendingSurfaceTitles = () => {
      if (titleFlushTimer !== undefined) clearTimeout(titleFlushTimer);
      titleFlushTimer = undefined;
      pendingSurfaceTitles.clear();
    };
    const flushSurfaceTitles = () => {
      titleFlushTimer = undefined;
      if (cancelled || pendingSurfaceTitles.size === 0) return;
      pendingSurfaceTitles.clear();
      setState((current) => current.tree === null
        ? current
        : { ...current, tree: titleReconciler.apply(current.tree) });
    };
    const queueSurfaceTitle = (surface: Id, title: string) => {
      titleReconciler.record(surface, title);
      pendingSurfaceTitles.set(surface, title);
      titleFlushTimer ??= setTimeout(flushSurfaceTitles, 0);
    };

    const refresh = async () => {
      if (!activeClient) return null;
      discardPendingSurfaceTitles();
      const token = titleReconciler.beginRefresh();
      const tree = await activeClient.listWorkspaces();
      const committed = titleReconciler.commit(tree, token);
      if (!cancelled && committed.applied) {
        setState((current) => ({ ...current, tree: committed.tree }));
        dispatchSelection({ type: "tree-updated", snapshot: selectionSnapshot(committed.tree) });
      }
      return committed.tree;
    };
    const queueClientsRefresh = createCoalescedRefresh(async () => {
      if (!activeClient) return;
      const generation = clientPresenceGeneration;
      const clients = await activeClient.listClients();
      if (!cancelled && generation === clientPresenceGeneration) {
        setState((current) => ({ ...current, clients }));
      }
    });
    clientsRefreshRef.current = queueClientsRefresh;
    refreshRef.current = refresh;

    const start = async (reconnecting: boolean, previousAttempt = 0): Promise<void> => {
      if (cancelled) return;
      // Retained title events belong to one transport generation. A restarted
      // server may reuse surface IDs, so no title state may cross reconnects.
      discardPendingSurfaceTitles();
      titleReconciler = new SurfaceTitleReconciler();
      let dropHandled = false;
      let canReconnect = false;
      const transport = new WebSocketTransport(config.url, {
        authToken: config.token ?? pairingCredential.current,
        onPairingChallenge: (pairing) => {
          if (!cancelled) {
            setState((current) => ({ ...current, status: "pairing", pairing, error: null }));
          }
        },
        onPairingCredential: (credential) => {
          pairingCredential.current = credential;
        },
        onAuthenticationRejected: () => {
          if (!config.token) pairingCredential.current = undefined;
        },
      });
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
          pairing: null,
        }));
        retryTimer = setTimeout(() => void start(true, step.attempt), step.delayMs);
      };
      transport.onClose(() => {
        if (canReconnect) scheduleRetry();
      });

      try {
        const info = await client.identify();
        if (info.app !== "cmux-tui") throw new Error(t("wrongApp", { app: info.app }));
        if (!supportsProtocol(info.protocol)) {
          throw new Error(t("wrongProtocol", {
            required: SUPPORTED_PROTOCOL,
            protocol: info.protocol,
          }));
        }
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
        setState({
          status: "connected",
          client,
          info,
          tree,
          clients,
          error: null,
          reconnect: null,
          pairing: null,
        });
        dispatchSelection({ type: "tree-updated", snapshot: selectionSnapshot(tree) });

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
            if (event.event === "title-changed") {
              const changed = event as TitleChangedEvent;
              if (changed.title === undefined) {
                discardPendingSurfaceTitles();
                await refresh();
              } else {
                queueSurfaceTitle(changed.surface, changed.title);
              }
            }
            // This frontend passes only live PTY tabs to useAttachedTerminal;
            // browser tabs render the unsupported placeholder and never call
            // resizeSurface. A surface-resize-failed broadcast therefore
            // belongs to another client and must not be echoed into a
            // multi-client retry loop. Browser rendering must track which
            // local size report produced the asynchronous failure first.
            if (["tree-changed", "layout-changed", "surface-resized", "surface-exited"].includes(event.event)) {
              discardPendingSurfaceTitles();
              await refresh();
            }
            if (
              event.event === "client-attached"
              || event.event === "client-changed"
              // Keep the client viewport list current after a shared resize.
              || event.event === "surface-resized"
            ) {
              if (event.event !== "surface-resized") clientPresenceGeneration += 1;
              queueClientsRefresh();
            }
            if (event.event === "client-detached") {
              const detached = event as ClientDetachedEvent;
              clientPresenceGeneration += 1;
              setState((current) => ({
                ...current,
                clients: current.clients.filter((item) => item.client !== detached.client),
              }));
              queueClientsRefresh();
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
            pairing: null,
          });
        }
      }
    };

    setState((current) => ({
      ...current,
      status: "connecting",
      error: null,
      reconnect: null,
      pairing: null,
    }));
    void start(false);
    return () => {
      cancelled = true;
      if (retryTimer !== undefined) clearTimeout(retryTimer);
      discardPendingSurfaceTitles();
      refreshRef.current = null;
      clientsRefreshRef.current = null;
      void activeClient?.close();
    };
  }, [config]);

  const connect = useCallback((next: ConnectionConfig) => {
    dispatchSelection({ type: "reset" });
    pairingCredential.current = undefined;
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

  const selectScreen = useCallback((workspaceId: Id, screenId: Id, surface: Id | null) => {
    dispatchSelection({ type: "navigate", workspaceId, screenId });
    if (surface !== null) setUnread((current) => {
      const next = new Set(current);
      next.delete(surface);
      return next;
    });
  }, []);

  const selectPane = useCallback((paneId: Id) => {
    dispatchSelection({ type: "select-pane", paneId });
  }, []);

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

  // Creation responses carry only the new surface id; selection is local, so
  // follow the creation by locating that surface in a fresh tree and
  // navigating there — only this client moves, per-client navigation intact.
  const createAndFollow = useCallback(
    (create: (client: CmuxClient) => Promise<{ surface: Id }>) =>
      runMutation(async (client) => {
        const created = await create(client);
        const tree = await refreshRef.current?.();
        if (!tree) return;
        const target = locateSurface(tree, created.surface);
        if (target) {
          dispatchSelection({ type: "navigate", workspaceId: target.workspaceId, screenId: target.screenId });
        }
      }),
    [runMutation],
  );

  const mutations = useMemo(() => ({
    newWorkspace: () => createAndFollow((client) => client.newWorkspace()),
    newScreen: (workspace: Id) => createAndFollow((client) => client.newScreen({ workspace })),
    newTab: (pane: Id) => runMutation((client) => client.newTab({ pane })),
    newBrowserTab: (pane: Id, url: string) => runMutation((client) => client.newBrowserTab(url, { pane })),
    split: (pane: Id, dir: "right" | "down") => runMutation((client) => client.split(pane, dir)),
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
    setSplitRatio: (split: Id, ratio: number) =>
      runMutation((client) => client.setSplitRatio(split, ratio)),
    setClientSizing: (clientId: Id, enabled: boolean) => runMutation(async (client) => {
      await client.setClientSizing(clientId, enabled);
    }),
    useOnlyClientSizing: (clientId: Id) => runMutation(async (client) => {
      await client.useOnlyClientSizing(clientId);
    }),
    useAllClientSizing: () => runMutation(async (client) => {
      await client.useAllClientSizing();
    }),
    detachClient: (clientId: Id) => runMutation(async (client) => {
      await client.detachClient(clientId);
      setState((current) => ({
        ...current,
        clients: current.clients.filter((item) => item.client !== clientId),
      }));
    }),
  }), [createAndFollow, runMutation]);

  const refreshClients = useCallback(() => {
    clientsRefreshRef.current?.();
  }, []);

  const dismissToast = useCallback((notification: Id) => {
    setToasts((current) => current.filter((toast) => toast.notification !== notification));
  }, []);

  const view = useMemo(
    () => state.tree ? treeToViewModel(state.tree, unread, selection) : [],
    [selection, state.tree, unread],
  );
  return {
    ...state,
    view,
    active: activeScreen(view),
    toasts,
    connect,
    selectScreen,
    selectPane,
    selectTab,
    mutations,
    refreshClients,
    dismissToast,
  };
}
