import type {
  ClientInfo,
  Id,
  IdentifyResult,
  Layout,
  Tree,
} from "cmux/raw";
import { t } from "../i18n";

export interface MacRuntimeEvent {
  kind: "event";
  topic: string;
  payload: Record<string, unknown>;
}

export interface MacRuntimeStream<T> {
  next(): Promise<T>;
  close(): void;
}

interface RPCResponse {
  id: number;
  ok: boolean;
  result?: Record<string, unknown>;
  error?: { code?: string; message?: string };
}

interface MacRuntimeWebSocketOptions {
  url: string;
  token: string;
}

class MacRuntimeWebSocket {
  private static readonly heartbeatIntervalMs = 10_000;
  private static readonly maximumClientMessageByteCount = 4 * 1024;
  private static readonly readyTimeoutMs = 10_000;
  private static readonly requestTimeoutMs = 15_000;
  private static readonly maximumPendingRequestCount = 128;
  private static readonly maximumQueuedEventCount = 256;
  private static readonly maximumQueuedEventBytes = 8 * 1024 * 1024;
  private readonly socket: WebSocket;
  private nextRequestID = 1;
  private readonly pending = new Map<number, {
    resolve: (value: Record<string, unknown>) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();
  private readonly eventWaiters: Array<(event: MacRuntimeEvent) => void> = [];
  private readonly eventQueue: Array<{ event: MacRuntimeEvent; weight: number }> = [];
  private eventQueueByteCount = 0;
  private readonly eventListeners = new Set<(event: MacRuntimeEvent) => void>();
  private readonly closeHandlers = new Set<() => void>();
  private readyPromise: Promise<void>;
  private readyReject: ((error: Error) => void) | null = null;
  private readySettled = false;
  private connectionID = "";
  private heartbeatTimer: ReturnType<typeof setTimeout> | undefined;
  private readyTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(options: MacRuntimeWebSocketOptions) {
    this.socket = new WebSocket(options.url, "cmux.web.v1");
    this.socket.binaryType = "arraybuffer";
    this.readyPromise = new Promise<void>((resolve, reject) => {
      this.readyReject = reject;
      this.readyTimer = setTimeout(() => {
        if (this.readySettled) return;
        this.readySettled = true;
        const error = new Error(t("macBridgeHandshakeTimedOut"));
        reject(error);
        this.socket.close();
      }, MacRuntimeWebSocket.readyTimeoutMs);
      this.socket.addEventListener("open", () => {
        this.socket.send(JSON.stringify({
          type: "cmux.web.hello",
          protocol: "cmux.web/1",
          protocol_version: 1,
          token: options.token,
        }));
      });
      this.socket.addEventListener("message", (message) => {
        void this.handleMessage(message.data, resolve, reject);
      });
      this.socket.addEventListener("error", () => {
        const error = new Error(t("webSocketConnectionFailed"));
        if (!this.readySettled) {
          this.readySettled = true;
          if (this.readyTimer !== undefined) clearTimeout(this.readyTimer);
          reject(error);
        }
        this.socket.close();
      });
      this.socket.addEventListener("close", () => {
        if (this.heartbeatTimer !== undefined) clearTimeout(this.heartbeatTimer);
        if (this.readyTimer !== undefined) clearTimeout(this.readyTimer);
        this.eventQueue.length = 0;
        this.eventQueueByteCount = 0;
        if (!this.readySettled) {
          this.readySettled = true;
          this.readyReject?.(new Error(t("webSocketClosedBeforeHandshake")));
        }
        for (const request of this.pending.values()) {
          clearTimeout(request.timer);
          request.reject(new Error(t("webSocketClosed")));
        }
        this.pending.clear();
        for (const handler of this.closeHandlers) handler();
      });
    });
  }

  onClose(handler: () => void): () => void {
    this.closeHandlers.add(handler);
    return () => this.closeHandlers.delete(handler);
  }

  clientID(): string {
    return this.connectionID;
  }

  async request(method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    await this.readyPromise;
    if (this.socket.readyState !== 1) {
      throw new Error(t("webSocketNotOpen"));
    }
    if (this.pending.size >= MacRuntimeWebSocket.maximumPendingRequestCount) {
      throw new Error(t("macBridgeRequestLimitReached"));
    }
    const id = this.nextRequestID++;
    const encodedRequest = JSON.stringify({
      id,
      protocol: "cmux.web/1",
      protocol_version: 1,
      method,
      params,
    });
    if (new TextEncoder().encode(encodedRequest).byteLength > MacRuntimeWebSocket.maximumClientMessageByteCount) {
      throw new Error(t("macBridgeRequestTooLarge"));
    }
    const response = new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(t("macBridgeRequestTimedOut")));
      }, MacRuntimeWebSocket.requestTimeoutMs);
      this.pending.set(id, { resolve, reject, timer });
    });
    try {
      this.socket.send(encodedRequest);
    } catch (error) {
      const request = this.pending.get(id);
      if (request) {
        clearTimeout(request.timer);
        this.pending.delete(id);
        request.reject(error instanceof Error ? error : new Error(String(error)));
      }
    }
    return response;
  }

  async nextEvent(): Promise<MacRuntimeEvent> {
    await this.readyPromise;
    const queued = this.eventQueue.shift();
    if (queued) {
      this.eventQueueByteCount = Math.max(0, this.eventQueueByteCount - queued.weight);
      return queued.event;
    }
    return new Promise<MacRuntimeEvent>((resolve) => this.eventWaiters.push(resolve));
  }

  onEvent(handler: (event: MacRuntimeEvent) => void): () => void {
    this.eventListeners.add(handler);
    while (this.eventQueue.length > 0) {
      const queued = this.eventQueue.shift()!;
      this.eventQueueByteCount = Math.max(0, this.eventQueueByteCount - queued.weight);
      handler(queued.event);
    }
    return () => this.eventListeners.delete(handler);
  }

  close(): void {
    this.socket.close();
  }

  private async handleMessage(
    raw: unknown,
    ready: () => void,
    rejectReady: (error: Error) => void,
  ): Promise<void> {
    let text: string;
    if (typeof raw === "string") {
      text = raw;
    } else if (raw instanceof ArrayBuffer) {
      text = new TextDecoder().decode(raw);
    } else if (raw instanceof Blob) {
      text = await raw.text();
    } else {
      this.failProtocol(new Error(t("webSocketUnsupportedMessage")), rejectReady);
      return;
    }
    let value: unknown;
    try {
      value = JSON.parse(text);
    } catch {
      this.failProtocol(new Error(t("macBridgeInvalidJSON")), rejectReady);
      return;
    }
    if (isRecord(value) && value.type === "cmux.web.ready") {
      if (value.protocol !== "cmux.web/1" || value.protocol_version !== 1) {
        this.failProtocol(new Error(t("macBridgeProtocolMismatch", {
          protocol: String(value.protocol),
        })), rejectReady);
        return;
      }
      if (typeof value.connection_id !== "string" || value.connection_id.trim().length === 0) {
        this.failProtocol(new Error(t("macBridgeInvalidResponse")), rejectReady);
        return;
      }
      this.connectionID = value.connection_id;
      if (!this.readySettled) {
        this.readySettled = true;
        if (this.readyTimer !== undefined) clearTimeout(this.readyTimer);
        ready();
        this.scheduleHeartbeat();
      }
      return;
    }
    if (isRecord(value) && value.kind === "event" && typeof value.topic === "string") {
      const event: MacRuntimeEvent = {
        kind: "event",
        topic: value.topic,
        payload: isRecord(value.payload) ? value.payload : {},
      };
      for (const listener of this.eventListeners) listener(event);
      if (this.eventListeners.size === 0) {
        const waiter = this.eventWaiters.shift();
        if (waiter) waiter(event);
        else {
          const weight = MacRuntimeWebSocket.estimatedEventWeight(text);
          if (
            weight > MacRuntimeWebSocket.maximumQueuedEventBytes
            || this.eventQueue.length >= MacRuntimeWebSocket.maximumQueuedEventCount
            || this.eventQueueByteCount + weight > MacRuntimeWebSocket.maximumQueuedEventBytes
          ) {
            // No stream listener can turn this backlog into a replay request,
            // so close and let the existing reconnect/attach path recover from
            // authoritative state instead of retaining unbounded payload data.
            this.eventQueue.length = 0;
            this.eventQueueByteCount = 0;
            this.socket.close();
            return;
          }
          this.eventQueue.push({ event, weight });
          this.eventQueueByteCount += weight;
        }
      }
      return;
    }
    if (!isRecord(value) || typeof value.id !== "number" || typeof value.ok !== "boolean") {
      this.failProtocol(new Error(t("macBridgeInvalidResponse")), rejectReady);
      return;
    }
    const response = value as unknown as RPCResponse;
    const request = this.pending.get(response.id);
    if (!request) return;
    this.pending.delete(response.id);
    clearTimeout(request.timer);
    if (response.ok) {
      request.resolve(response.result ?? {});
    } else {
      request.reject(new Error(response.error?.message ?? response.error?.code ?? t("macBridgeRequestFailed")));
    }
  }

  private failProtocol(error: Error, rejectReady: (error: Error) => void): void {
    if (!this.readySettled) {
      this.readySettled = true;
      if (this.readyTimer !== undefined) clearTimeout(this.readyTimer);
      rejectReady(error);
    }
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    this.pending.clear();
    this.socket.close();
  }

  private static estimatedEventWeight(text: string): number {
    // A JS string may use two bytes per UTF-16 code unit, before parsed object
    // and base64 copies. This conservative estimate keeps the raw backlog
    // bounded without allocating a second encoded buffer on every event.
    return Math.max(1, Math.min(Number.MAX_SAFE_INTEGER, text.length * 2));
  }

  private scheduleHeartbeat(): void {
    if (this.socket.readyState !== WebSocket.OPEN) return;
    if (this.heartbeatTimer !== undefined) clearTimeout(this.heartbeatTimer);
    this.heartbeatTimer = setTimeout(() => {
      this.heartbeatTimer = undefined;
      void this.runHeartbeat();
    }, MacRuntimeWebSocket.heartbeatIntervalMs);
  }

  private async runHeartbeat(): Promise<void> {
    if (this.socket.readyState !== WebSocket.OPEN) return;
    try {
      await this.request("mobile.host.status");
      this.scheduleHeartbeat();
    } catch {
      this.socket.close();
    }
  }
}

class BoundedAsyncQueueOverflowError extends Error {}

class BoundedAsyncQueue<T> {
  private readonly values: T[] = [];
  private readonly waiters: Array<{
    resolve: (value: T) => void;
    reject: (error: Error) => void;
  }> = [];
  private overflowed = false;
  private closed = false;
  private closeError: Error | null = null;
  private bufferedWeight = 0;

  constructor(
    private readonly limit: number,
    private readonly maximumWeight = Number.POSITIVE_INFINITY,
    private readonly measure: (value: T) => number = () => 1,
  ) {}

  push(value: T): void {
    if (this.closed) return;
    if (this.overflowed) return;
    const waiter = this.waiters.shift();
    if (waiter) {
      waiter.resolve(value);
      return;
    }
    const weight = Math.max(0, this.measure(value));
    if (this.values.length >= this.limit || this.bufferedWeight + weight > this.maximumWeight) {
      this.markOverflow();
      return;
    }
    this.values.push(value);
    this.bufferedWeight += weight;
  }

  next(): Promise<T> {
    if (this.closed) return Promise.reject(this.closeError ?? new Error(t("streamClosed")));
    if (this.overflowed) {
      this.overflowed = false;
      return Promise.reject(new BoundedAsyncQueueOverflowError());
    }
    if (this.values.length > 0) {
      const value = this.values.shift()!;
      this.bufferedWeight = Math.max(0, this.bufferedWeight - this.measure(value));
      return Promise.resolve(value);
    }
    return new Promise<T>((resolve, reject) => this.waiters.push({ resolve, reject }));
  }

  markOverflow(): void {
    if (this.closed || this.overflowed) return;
    this.discardValues();
    const waiter = this.waiters.shift();
    if (waiter) waiter.reject(new BoundedAsyncQueueOverflowError());
    else this.overflowed = true;
  }

  replace(value: T): void {
    if (this.closed) return;
    this.discardValues();
    this.overflowed = false;
    const waiter = this.waiters.shift();
    if (waiter) {
      waiter.resolve(value);
      return;
    }
    this.values.push(value);
    this.bufferedWeight = Math.max(0, this.measure(value));
  }

  close(error = new Error(t("streamClosed"))): void {
    if (this.closed) return;
    this.closed = true;
    this.closeError = error;
    this.discardValues();
    for (const waiter of this.waiters) waiter.reject(error);
    this.waiters.length = 0;
  }

  private discardValues(): void {
    this.values.length = 0;
    this.bufferedWeight = 0;
  }
}

/**
 * Browser client for the Mac-as-host bridge. It mirrors the subset of the
 * cmux-tui client surface consumed by the shared xterm shell, so the frontend
 * keeps one rendering/mutation UI while the wire protocol stays the Mac
 * runtime's v2 JSON-RPC contract.
 */
export class MacRuntimeClient {
  readonly protocol = 6;
  private readonly transport: MacRuntimeWebSocket;
  private readonly uuidByID = new Map<Id, string>();
  private readonly idByUUID = new Map<string, Id>();
  private nextTreeID: Id = 1n;
  private readonly paneTabs = new Map<Id, Id[]>();
  private readonly activeSurfaceByPane = new Map<Id, Id>();
  private readonly surfaceReplayHandlers = new Map<string, (payload: Record<string, unknown>) => void>();
  private readonly surfaceReplayRequests = new Map<string, Promise<void>>();
  private nextStreamID = 1;

  constructor(url: string, token: string) {
    this.transport = new MacRuntimeWebSocket({ url, token });
  }

  onClose(handler: () => void): void {
    this.transport.onClose(handler);
  }

  async identify(): Promise<IdentifyResult> {
    const status = await this.transport.request("mobile.host.status");
    return {
      app: "cmux-tui",
      protocol: this.protocol,
      daemon_handoff: 1,
      generation: String(status.mac_device_id ?? "mac-runtime"),
      pid: 0,
      registry_id: String(status.mac_device_id ?? "mac-runtime"),
      session: "mac",
      terminal_revision: 0n,
      version: "cmux-mac",
      workspace_revision: 0n,
      capabilities: Array.isArray(status.capabilities)
        ? status.capabilities.filter((item): item is string => typeof item === "string")
        : [],
    };
  }

  async listWorkspaces(): Promise<Tree> {
    const payload = await this.transport.request("mobile.workspace.list");
    return this.treeFromPayload(payload);
  }

  async listClients(): Promise<ClientInfo[]> {
    return [{
      attached: [],
      client: 1n,
      connected_seconds: 0n,
      kind: "web",
      name: t("macBrowserClientName"),
      self: true,
      sizes: [],
      transport: "ws",
    }];
  }

  async setClientInfo(): Promise<void> {
    // The Mac bridge identifies browser clients from the grant-bound socket.
  }

  async subscribe(): Promise<MacRuntimeStream<Record<string, unknown>>> {
    const streamID = this.makeStreamID("web-ui");
    await this.transport.request("events.stream", {
      stream_id: streamID,
      topics: ["workspace.updated"],
    });
    // workspace.updated is level-triggered; one queued refresh signal is
    // sufficient no matter how many mutations arrive while a list fetch runs.
    const queue = new BoundedAsyncQueue<Record<string, unknown>>(1);
    const removeListener = this.transport.onEvent((event) => {
      const mapped = this.mapEvent(event);
      if (mapped) queue.push(mapped);
    });
    const removeClose = this.transport.onClose(() => queue.close(new Error(t("macBridgeDisconnected"))));
    return {
      next: async () => {
        try {
          return await queue.next();
        } catch (error) {
          if (error instanceof BoundedAsyncQueueOverflowError) {
            return { event: "tree-changed" };
          }
          throw error;
        }
      },
      close: () => {
        removeListener();
        removeClose();
        void this.transport.request("events.cancel", { stream_id: streamID }).catch(() => undefined);
        queue.close();
      },
    };
  }

  async attachSurface(surface: Id): Promise<MacRuntimeStream<Record<string, unknown>>> {
    const uuid = this.uuidFor(surface);
    const streamID = this.makeStreamID("terminal");
    let initial: Record<string, unknown> | null | undefined;
    let nextReceivedSequence: bigint | null = null;
    let nextDeliveredSequence: bigint | null = null;
    const queue = new BoundedAsyncQueue<Record<string, unknown>>(
      128,
      8 * 1024 * 1024,
      (event) => event.data instanceof Uint8Array ? event.data.byteLength : 0,
    );
    const removeListener = this.transport.onEvent((event) => {
      if (event.topic !== "terminal.bytes" || event.payload.surface_id !== uuid) return;
      const sequence = parseSequence(event.payload.seq_decimal ?? event.payload.seq);
      let data: Uint8Array;
      try {
        data = decodeBase64(String(event.payload.data_b64 ?? ""));
      } catch {
        queue.markOverflow();
        return;
      }
      if (
        nextReceivedSequence !== null
        && sequence !== null
        && sequence !== nextReceivedSequence
      ) {
        queue.markOverflow();
      }
      if (sequence !== null) nextReceivedSequence = sequence + BigInt(data.byteLength);
      const mapped = {
        event: "output",
        surface,
        data,
        __sequence: sequence,
      };
      queue.push(mapped);
    });
    this.surfaceReplayHandlers.set(uuid, (payload) => {
      const replayEvent = this.replayEvent(surface, payload);
      const replaySequence = parseSequence(payload.seq_decimal ?? payload.seq);
      if (replaySequence !== null) {
        nextDeliveredSequence = replaySequence;
        nextReceivedSequence = replaySequence;
      }
      queue.replace(replayEvent);
    });
    const removeClose = this.transport.onClose(() => queue.close(new Error(t("macBridgeDisconnected"))));
    let replayPromise: Promise<
      { payload: Record<string, unknown> } | { error: Error }
    >;
    try {
      await this.transport.request("terminal.attach", {
        stream_id: streamID,
        surface_id: uuid,
      });
      replayPromise = this.transport.request("terminal.replay", {
        surface_id: uuid,
        prefer_bytes: true,
      }).then(
        (payload) => ({ payload }),
        (error: unknown) => ({
          error: error instanceof Error ? error : new Error(String(error)),
        }),
      );
    } catch (error) {
      removeListener();
      removeClose();
      this.surfaceReplayHandlers.delete(uuid);
      queue.close(error instanceof Error ? error : new Error(String(error)));
      throw error;
    }
    const replay = async (): Promise<Record<string, unknown>> => {
      const recovered = await this.transport.request("terminal.replay", {
        surface_id: uuid,
        prefer_bytes: true,
      });
      const replaySequence = parseSequence(recovered.seq_decimal ?? recovered.seq);
      if (replaySequence !== null) {
        nextDeliveredSequence = replaySequence;
        if (nextReceivedSequence === null || nextReceivedSequence < replaySequence) {
          nextReceivedSequence = replaySequence;
        }
      }
      return recovered;
    };
    return {
      next: async () => {
        if (initial === undefined) {
          const replayOutcome = await replayPromise;
          if ("error" in replayOutcome) throw replayOutcome.error;
          const replay = replayOutcome.payload;
          initial = this.replayEvent(surface, replay);
          const replaySequence = parseSequence(replay.seq_decimal ?? replay.seq);
          if (replaySequence !== null) {
            nextDeliveredSequence = replaySequence;
            if (nextReceivedSequence === null || nextReceivedSequence < replaySequence) {
              nextReceivedSequence = replaySequence;
            }
          }
        }
        if (initial !== null) {
          const first = initial;
          initial = null;
          return first;
        }
        for (;;) {
          let event: Record<string, unknown>;
          try {
            event = await queue.next();
          } catch (error) {
            if (error instanceof BoundedAsyncQueueOverflowError) {
              const recovered = await replay();
              return this.replayEvent(surface, recovered);
            }
            throw error;
          }
          const sequence = parseSequence(event.__sequence);
          if (
            sequence !== null
            && nextDeliveredSequence !== null
            && sequence < nextDeliveredSequence
          ) {
            continue;
          }
          if (
            sequence !== null
            && nextDeliveredSequence !== null
            && sequence > nextDeliveredSequence
          ) {
            queue.markOverflow();
            continue;
          }
          if (sequence !== null) {
            nextDeliveredSequence = sequence + BigInt(
              event.data instanceof Uint8Array ? event.data.byteLength : 0,
            );
          }
          delete event.__sequence;
          return event;
        }
      },
      close: () => {
        removeListener();
        removeClose();
        this.surfaceReplayHandlers.delete(uuid);
        void this.transport.request("events.cancel", { stream_id: streamID }).catch(() => undefined);
        queue.close();
      },
    };
  }

  async releaseSurfaceSize(surface: Id): Promise<void> {
    const response = await this.transport.request("terminal.viewport", {
      surface_id: this.uuidFor(surface),
      client_id: this.viewportClientID,
      clear: true,
    });
    await this.replayAfterEffectiveViewportChange(surface, response, null);
  }

  async resizeSurface(surface: Id, cols: number, rows: number): Promise<void> {
    const response = await this.transport.request("terminal.viewport", {
      surface_id: this.uuidFor(surface),
      client_id: this.viewportClientID,
      viewport_columns: cols,
      viewport_rows: rows,
    });
    await this.replayAfterEffectiveViewportChange(surface, response, { cols, rows });
  }

  async send(surface: Id, options: { text: string }): Promise<void> {
    const surfaceID = this.uuidFor(surface);
    for (const text of terminalInputChunks(options.text)) {
      await this.transport.request("terminal.input", {
        surface_id: surfaceID,
        text,
      });
    }
  }

  async sendKey(surface: Id, keys: string[]): Promise<void> {
    for (const key of keys) {
      await this.send(surface, { text: terminalKeyText(key) });
    }
  }

  async readScrollback(): Promise<never[]> {
    return [];
  }

  async newWorkspace(): Promise<{ surface: Id }> {
    throw new Error(t("macBridgeUnsupportedWorkspaceCreation"));
  }

  async closeWorkspace(_workspace: Id): Promise<void> {
    throw new Error(t("macBridgeUnsupportedWorkspaceClose"));
  }

  async close(): Promise<void> {
    this.transport.close();
  }

  async newScreen(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async newTab(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async newBrowserTab(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async split(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async closeScreen(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async closePane(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async closeSurface(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async renameWorkspace(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async renameScreen(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async renamePane(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async renameSurface(): Promise<never> { throw new Error(t("macBridgeUnsupportedMutation")); }
  async selectTab(options: { pane: Id; index: bigint }): Promise<void> {
    const surface = this.paneTabs.get(options.pane)?.[Number(options.index)];
    if (surface === undefined) return;
    this.activeSurfaceByPane.set(options.pane, surface);
  }
  async zoomPane(): Promise<void> {}
  async swapPane(): Promise<void> {}
  async setSplitRatio(): Promise<boolean> { return false; }
  async setClientSizing(): Promise<void> {}
  async useOnlyClientSizing(): Promise<void> {}
  async useAllClientSizing(): Promise<void> {}
  async detachClient(): Promise<void> {}

  private mapEvent(event: MacRuntimeEvent): Record<string, unknown> | null {
    if (event.topic === "workspace.updated") {
      return { event: "tree-changed" };
    }
    return null;
  }

  private replayEvent(surface: Id, payload: Record<string, unknown>): Record<string, unknown> {
    const columns = Number(payload.columns ?? 80);
    const rows = Number(payload.rows ?? 24);
    const encoded = payload.snapshot_data_b64 ?? payload.data_b64;
    return {
      event: "vt-state",
      surface,
      cols: columns,
      rows,
      data: typeof encoded === "string" ? decodeBase64(encoded) : new Uint8Array(),
    };
  }

  private treeFromPayload(payload: Record<string, unknown>): Tree {
    const rawWorkspaces = Array.isArray(payload.workspaces) ? payload.workspaces : [];
    const liveUUIDs = new Set<string>();
    const livePaneIDs = new Set<Id>();
    const treeID = (uuid: string): Id => {
      const normalized = uuid.trim() || "empty";
      liveUUIDs.add(normalized);
      return this.idFor(normalized);
    };
    const workspaces = rawWorkspaces.filter(isRecord).map((workspace) => {
      const workspaceUUID = String(workspace.id ?? "");
      const workspaceID = treeID(workspaceUUID);
      const screenID = treeID(workspaceUUID + ":screen");
      const paneID = treeID(workspaceUUID + ":pane");
      livePaneIDs.add(paneID);
      const terminals = Array.isArray(workspace.terminals) ? workspace.terminals : [];
      const tabs = terminals.filter(isRecord).map((terminal) => {
        const surfaceUUID = String(terminal.id ?? "");
        const surface = treeID(surfaceUUID);
        return {
          surface,
          kind: "pty" as const,
          browser_source: null,
          name: null,
          title: String(terminal.title ?? t("terminal")),
          size: null,
          dead: terminal.is_ready === false,
        };
      });
      const tabIDs = tabs.map(({ surface }) => surface);
      this.paneTabs.set(paneID, tabIDs);
      let activeSurface = this.activeSurfaceByPane.get(paneID);
      if (activeSurface !== undefined && !tabIDs.includes(activeSurface)) {
        this.activeSurfaceByPane.delete(paneID);
        activeSurface = undefined;
      }
      const focusedIndex = terminals.findIndex((terminal) => (
        isRecord(terminal) && terminal.is_focused === true
      ));
      const activeIndex = activeSurface === undefined
        ? Math.max(0, focusedIndex)
        : Math.max(0, tabIDs.indexOf(activeSurface));
      const layout: Layout = { type: "leaf", pane: paneID };
      return {
        id: workspaceID,
        name: String(workspace.title ?? workspace.name ?? workspaceUUID),
        active: workspace.is_selected === true,
        screens: [{
          id: screenID,
          name: null,
          active: true,
          active_pane: paneID,
          zoomed_pane: null,
          layout,
          panes: [{
            id: paneID,
            name: null,
            active_tab: BigInt(activeIndex),
            tabs,
          }],
        }],
      };
    });
    for (const [uuid, id] of this.idByUUID) {
      // React applies the previous tree's component cleanup after this
      // refresh commits. Keep the real UUID for an attachment that is still
      // mounted so its cleanup can clear the server-side viewport report
      // before the synthetic bigint handle is eligible for eviction.
      if (liveUUIDs.has(uuid) || this.surfaceReplayHandlers.has(uuid)) continue;
      this.idByUUID.delete(uuid);
      if (this.uuidByID.get(id) === uuid) this.uuidByID.delete(id);
    }
    for (const pane of this.paneTabs.keys()) {
      if (livePaneIDs.has(pane)) continue;
      this.paneTabs.delete(pane);
      this.activeSurfaceByPane.delete(pane);
    }
    return {
      workspaces,
    };
  }

  private idFor(uuid: string): Id {
    const normalized = uuid.trim() || "empty";
    const existing = this.idByUUID.get(normalized);
    if (existing !== undefined) return existing;
    // IDs are opaque handles. A monotonic allocator avoids hash collisions
    // while the two maps preserve stability for UUIDs that remain mounted.
    let id: Id;
    while (true) {
      const candidate = this.nextTreeID;
      this.nextTreeID += 1n;
      if (this.nextTreeID === 0n) this.nextTreeID = 1n;
      if (candidate !== 0n && !this.uuidByID.has(candidate)) {
        id = candidate;
        break;
      }
    }
    this.uuidByID.set(id, normalized);
    this.idByUUID.set(normalized, id);
    return id;
  }

  private uuidFor(id: Id): string {
    return this.uuidByID.get(id) ?? String(id);
  }

  private get viewportClientID(): string {
    const connectionID = this.transport.clientID();
    return connectionID ? "web:" + connectionID : "web:pending";
  }

  private makeStreamID(prefix: string): string {
    const sequence = this.nextStreamID++;
    const suffix = typeof crypto.randomUUID === "function"
      ? crypto.randomUUID()
      : `${Date.now()}-${sequence}`;
    return `${prefix}-${suffix}`;
  }

  private async replayAfterEffectiveViewportChange(
    surface: Id,
    response: Record<string, unknown>,
    requested: { cols: number; rows: number } | null,
  ): Promise<void> {
    const effectiveColumns = Number(response.columns);
    const effectiveRows = Number(response.rows);
    if (!Number.isInteger(effectiveColumns) || !Number.isInteger(effectiveRows)
      || effectiveColumns <= 0 || effectiveRows <= 0) return;
    if (requested !== null
      && requested.cols === effectiveColumns
      && requested.rows === effectiveRows) return;
    const uuid = this.uuidFor(surface);
    const handler = this.surfaceReplayHandlers.get(uuid);
    if (!handler) return;
    const existing = this.surfaceReplayRequests.get(uuid);
    if (existing) return existing;
    const request = this.transport.request("terminal.replay", {
      surface_id: uuid,
      prefer_bytes: true,
    }).then((payload) => {
      handler(payload);
    }).finally(() => {
      this.surfaceReplayRequests.delete(uuid);
    });
    this.surfaceReplayRequests.set(uuid, request);
    return request;
  }
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function parseSequence(value: unknown): bigint | null {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isSafeInteger(value)) return BigInt(value);
  if (typeof value === "string" && /^[0-9]+$/.test(value)) return BigInt(value);
  return null;
}

function terminalKeyText(value: string): string {
  const parts = value.toLowerCase().split("+");
  const key = parts.pop() ?? "";
  const modifiers = new Set(parts);
  const named: Record<string, string> = {
    enter: "\r",
    return: "\r",
    tab: "\t",
    backtab: "\u001b[Z",
    escape: "\u001b",
    esc: "\u001b",
    backspace: "\u007f",
    delete: "\u001b[3~",
    insert: "\u001b[2~",
    home: "\u001b[H",
    end: "\u001b[F",
    pageup: "\u001b[5~",
    "page-up": "\u001b[5~",
    pagedown: "\u001b[6~",
    "page-down": "\u001b[6~",
    left: "\u001b[D",
    "arrow-left": "\u001b[D",
    up: "\u001b[A",
    "arrow-up": "\u001b[A",
    right: "\u001b[C",
    "arrow-right": "\u001b[C",
    down: "\u001b[B",
    "arrow-down": "\u001b[B",
    f1: "\u001bOP",
    f2: "\u001bOQ",
    f3: "\u001bOR",
    f4: "\u001bOS",
    f5: "\u001b[15~",
    f6: "\u001b[17~",
    f7: "\u001b[18~",
    f8: "\u001b[19~",
    f9: "\u001b[20~",
    f10: "\u001b[21~",
    f11: "\u001b[23~",
    f12: "\u001b[24~",
    space: " ",
    " ": " ",
  };
  let text = modifiers.has("shift") && key === "tab"
    ? "\u001b[Z"
    : named[key] ?? (key.length === 1 ? key : value);
  if (modifiers.has("shift") && key.length === 1 && !modifiers.has("ctrl")) {
    text = key.toUpperCase();
  }
  if (modifiers.has("ctrl") && key.length === 1) {
    const code = key.toUpperCase().charCodeAt(0);
    if (code >= 0x40 && code <= 0x5f) text = String.fromCharCode(code & 0x1f);
    else if (key === "2" || key === " " || key === "space") text = "\u0000";
    else if (key === "?") text = "\u007f";
  }
  if (modifiers.has("alt")) text = `\u001b${text}`;
  return text;
}

function terminalInputChunks(value: string): string[] {
  if (value.length === 0) return [""];
  const maximumUTF8Bytes = 512;
  const chunks: string[] = [];
  let current = "";
  let currentByteCount = 0;
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    const byteCount = codePoint <= 0x7f
      ? 1
      : codePoint <= 0x7ff
        ? 2
        : codePoint <= 0xffff ? 3 : 4;
    if (current.length > 0 && currentByteCount + byteCount > maximumUTF8Bytes) {
      chunks.push(current);
      current = "";
      currentByteCount = 0;
    }
    current += character;
    currentByteCount += byteCount;
  }
  if (current.length > 0) chunks.push(current);
  return chunks;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
