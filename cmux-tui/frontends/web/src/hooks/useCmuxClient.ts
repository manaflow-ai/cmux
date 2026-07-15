import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  CmuxClient,
  CmuxTimeoutError,
  WebSocketTransport,
  type Id,
  type IdentifyResult,
  type NotificationEvent,
  type Tree,
} from "cmux/browser";
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
  error: string | null;
  reconnect: ReconnectState | null;
}

const initialState: ConnectionState = {
  status: "idle",
  client: null,
  info: null,
  tree: null,
  error: null,
  reconnect: null,
};

export function useCmuxClient() {
  const [config, setConfig] = useState<ConnectionConfig | null>(null);
  const [state, setState] = useState<ConnectionState>(initialState);
  const [unread, setUnread] = useState<Set<Id>>(() => new Set());
  const [toasts, setToasts] = useState<Toast[]>([]);
  const refreshRef = useRef<(() => Promise<void>) | null>(null);

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
        const events = await client.subscribe();
        const tree = await client.listWorkspaces();
        if (cancelled) return;
        canReconnect = true;
        // A successful (re)connect resets the retry baseline so the next drop
        // starts from the first backoff step, not the cap.
        previousAttempt = 0;
        setState({ status: "connected", client, info, tree, error: null, reconnect: null });

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

  const selectScreen = useCallback(async (workspaceIndex: number, screenIndex: number, surface: Id | null) => {
    if (!state.client) return;
    await state.client.selectWorkspace({ index: workspaceIndex });
    await state.client.selectScreen({ index: screenIndex });
    if (surface !== null) setUnread((current) => {
      const next = new Set(current);
      next.delete(surface);
      return next;
    });
    await refreshRef.current?.();
  }, [state.client]);

  const selectTab = useCallback(async (pane: Id, index: number, surface: Id) => {
    if (!state.client) return;
    await state.client.selectTab({ pane, index });
    setUnread((current) => {
      const next = new Set(current);
      next.delete(surface);
      return next;
    });
    await refreshRef.current?.();
  }, [state.client]);

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
    dismissToast,
  };
}
