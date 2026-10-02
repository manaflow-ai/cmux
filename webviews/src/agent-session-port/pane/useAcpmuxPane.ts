// The pane's connection to acpmux: handshake with Swift, the direct client, the snapshot it
// folds, the actions the host and the page call, and the host theme. One hook with one
// effect (the connection's lifetime), so the components stay effect-free.
import { useEffect, useRef, useState } from "react";
import {
  AcpmuxDirectClient,
  MockAcpmuxSocket,
  applyAgentTheme,
  mockHost,
  paneContext,
  type AcpmuxHostConfig,
  type AcpmuxSnapshot,
} from "../data/acpmux";
import { callNative, type HostHandshake } from "../data/host";

const EMPTY: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connecting",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
};

export type PaneConnection = {
  snapshot: AcpmuxSnapshot;
  /** A draft a chat opened from another tab inherited. */
  draft?: string;
  mock: boolean;
};

const RECONNECT_MAX_DELAY_MS = 2_000;

export function useAcpmuxPane(): PaneConnection {
  const [snapshot, setSnapshot] = useState<AcpmuxSnapshot>(EMPTY);
  const [draft, setDraft] = useState<string>();
  const [mock, setMock] = useState(false);
  const snapshotRef = useRef(snapshot);
  snapshotRef.current = snapshot;
  useEffect(() => {
    // Swift calls these on the page (AgentPaneView): theme, customization, legacy pushes.
    window.cmuxAcpmuxBridge = {
      receive(next) {
        if (next.protocolVersion === 1) setSnapshot(next);
      },
      applyTheme(theme) {
        applyAgentTheme(theme as never);
      },
      applyCustomization(customization) {
        if (!("themeCSS" in customization)) return;
        let style = document.getElementById("acpmux-user-theme") as HTMLStyleElement | null;
        if (!style) {
          style = document.createElement("style");
          style.id = "acpmux-user-theme";
          document.head.append(style);
        }
        style.textContent = customization.themeCSS ?? "";
      },
    };
    let cancelled = false;
    let client: AcpmuxDirectClient | undefined;
    let retryTimer: number | undefined;
    let retryDelay = 250;
    let reconnect = false;
    const retry = () => {
      retryTimer = window.setTimeout(() => void connect(), retryDelay);
      retryDelay = Math.min(retryDelay * 2, reconnect ? RECONNECT_MAX_DELAY_MS : 30_000);
    };
    const connect = async () => {
      try {
        const host = await callNative<HostHandshake>("ready", reconnect ? { reconnect } : {});
        if (cancelled) return;
        if (host.draft) setDraft(host.draft);
        const isMock = host.transport === "mock";
        setMock(isMock);
        if (!isMock && (host.transport !== "acpmux-websocket" || !host.endpoint || !host.token)) return;
        const made = await AcpmuxDirectClient.connect(
          isMock ? mockHost : (host as AcpmuxHostConfig),
          (next) => setSnapshot(next),
          () => {
            if (cancelled) return;
            reconnect = true;
            client = undefined;
            delete window.cmuxAcpmuxActions;
            retry();
          },
          isMock
            ? () => new MockAcpmuxSocket(undefined, window.cmuxAcpmuxMockScript) as unknown as WebSocket
            : undefined,
        );
        if (cancelled) {
          made.close();
          return;
        }
        client = made;
        retryDelay = 250;
        const persist = (sessionId?: string) =>
          sessionId && !isMock
            ? callNative("chat.persistSession", { sessionId }).catch(() => undefined)
            : Promise.resolve();
        // The same action names the current pane registers, so Swift and the debug socket
        // drive either page.
        window.cmuxAcpmuxActions = {
          ...(window.cmuxAcpmuxActions?.ready ? { ready: window.cmuxAcpmuxActions.ready } : {}),
          "chat.send": async ({ text }) => {
            await persist(await made.ensureSession());
            return made.send(String(text ?? ""));
          },
          "chat.cancel": () => made.cancel(),
          "chat.permission": ({ permissionId, optionId }) => made.permission(String(permissionId), String(optionId)),
          "chat.model": ({ modelId }) => made.setModel(String(modelId)),
          "chat.mode": ({ modeId }) => made.setMode(String(modeId)),
          "chat.effort": ({ configId, value }) => made.setConfig(String(configId), String(value)),
          "chat.select": async ({ sessionId }) => persist(await made.select(String(sessionId))),
          "chat.new": async ({ harness }) => persist(await made.create(harness ? String(harness) : undefined)),
          "chat.history": () => made.loadOlder(),
          "pane.context": async () => paneContext(snapshotRef.current),
        };
        made.snapshot();
      } catch (error) {
        if (cancelled) return;
        setSnapshot((current) => ({ ...current, connection: `connecting: ${String(error)}` }));
        retry();
      }
    };
    void connect();
    return () => {
      cancelled = true;
      if (retryTimer !== undefined) window.clearTimeout(retryTimer);
      client?.close();
      delete window.cmuxAcpmuxActions;
    };
  }, []);
  return { snapshot, draft, mock };
}

/** Runs a pane action (registered above, or the Swift host's). Failures surface in the snapshot. */
export const act = (method: string, params: Record<string, unknown> = {}) =>
  void callNative(method, params).catch(() => undefined);
