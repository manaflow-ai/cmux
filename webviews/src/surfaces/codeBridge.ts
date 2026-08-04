const HTTP_ORIGIN = "https://cmux-code.invalid";
const WEBSOCKET_ORIGIN = "wss://cmux-code.invalid";
const NATIVE_BEARER_SENTINEL = "cmux-native";
const CLIENT_SETTINGS_KEY = "cmux:code-client-settings";
const CONNECTION_CATALOG_KEY = "cmux:code-connection-catalog";
const NATIVE_SOCKET_OPEN_EVENT = "cmux-code-native-socket-open";

interface NativeCodeMessageHandler {
  postMessage(message: unknown): Promise<unknown>;
}

interface NativeFetchResponse {
  bodyBase64: string;
  headers: Record<string, string>;
  status: number;
  statusText: string;
}

type FetchLike = {
  (input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
  preconnect?: typeof fetch.preconnect;
};

type NativeSocketEvent =
  | { id: string; type: "open"; protocol: string }
  | { id: string; type: "message"; kind: "text" | "binary"; payload: string }
  | { id: string; type: "error" }
  | {
      id: string;
      type: "close";
      code: number;
      reason: string;
      wasClean: boolean;
    };

export interface CmuxCodeBridge {
  mount(): Promise<void>;
  stopPrewarmHealthMonitoring(): void;
  __receiveSocketEvent(event: NativeSocketEvent): void;
}

function nativeHandler(): NativeCodeMessageHandler {
  const handler = window.webkit?.messageHandlers?.cmuxCode;
  if (!handler) {
    throw new Error("Code native bridge is unavailable");
  }
  return handler;
}

let mountPromise: Promise<void> | null = null;
let installedBridge: CmuxCodeBridge | null = null;
let originalGlobalFetch: typeof globalThis.fetch | null = null;
let originalGlobalWebSocket: typeof globalThis.WebSocket | null = null;
let nativeSocketHasOpened = false;
let nativeReadyReportPending = false;
let nativeReadyReported = false;
let stopReadinessWatch: (() => void) | null = null;

export function ensureCodeMounted(): Promise<void> {
  mountPromise ??= nativeHandler()
    .postMessage({ type: "mount" })
    .then(() => undefined)
    .catch((error) => {
      mountPromise = null;
      throw error;
    });
  return mountPromise;
}

export function __resetCodeBridgeForTests(): void {
  mountPromise = null;
  installedBridge = null;
  socketRegistry.clear();
  if (originalGlobalFetch) globalThis.fetch = originalGlobalFetch;
  if (originalGlobalWebSocket) globalThis.WebSocket = originalGlobalWebSocket;
  originalGlobalFetch = null;
  originalGlobalWebSocket = null;
  nativeSocketHasOpened = false;
  nativeReadyReportPending = false;
  nativeReadyReported = false;
  stopReadinessWatch?.();
  stopReadinessWatch = null;
}

function hasRenderedActualClient(root: HTMLElement | null): boolean {
  const hasUnavailableConnectionBanner = Array.from(
    root?.querySelectorAll<HTMLElement>('[data-slot="alert"]') ?? [],
  ).some((alert) => {
    const actions =
      alert.querySelector<HTMLElement>('[data-slot="alert-action"]')?.textContent ?? "";
    return actions.includes("Connections") && actions.includes("Reconnect");
  });
  return Boolean(
    root?.querySelector('[data-slot="sidebar-wrapper"]') &&
      root.querySelector(
        'textarea:not([disabled]), [contenteditable="true"][role="textbox"], [data-slot="empty"]',
      ) &&
      !hasUnavailableConnectionBanner,
  );
}

export function markNativeCodeSocketOpened(): void {
  if (nativeSocketHasOpened) return;
  nativeSocketHasOpened = true;
  window.dispatchEvent(new window.Event(NATIVE_SOCKET_OPEN_EVENT));
}

function markNativeCodeSocketClosed(): void {
  if (Array.from(socketRegistry.values()).some((socket) => socket.readyState === WebSocket.OPEN)) {
    return;
  }
  if (!nativeSocketHasOpened) return;
  nativeSocketHasOpened = false;
  window.dispatchEvent(new window.Event(NATIVE_SOCKET_OPEN_EVENT));
}

export function reportActualCodeSurfaceReady(): boolean {
  if (nativeReadyReportPending) return false;
  const root = window.document.getElementById("root");
  const isReady = nativeSocketHasOpened && hasRenderedActualClient(root);
  if (isReady === nativeReadyReported) return false;
  if (!isReady && !nativeReadyReported) return false;
  nativeReadyReportPending = true;
  void nativeHandler()
    .postMessage({ type: isReady ? "ready" : "unready" })
    .then(() => {
      nativeReadyReportPending = false;
      nativeReadyReported = isReady;
      if (isReady) {
        window.performance?.mark?.("cmux-code-actual-ready");
      }
      reportActualCodeSurfaceReady();
    })
    .catch(() => {
      nativeReadyReportPending = false;
    });
  return true;
}

export function watchForActualCodeSurfaceReadiness(): void {
  if (stopReadinessWatch) return;
  const root = window.document.getElementById("root");
  if (!root) {
    window.document.addEventListener("DOMContentLoaded", watchForActualCodeSurfaceReadiness, {
      once: true,
    });
    return;
  }
  const observer = new window.MutationObserver(reportActualCodeSurfaceReady);
  const cleanup = () => {
    window.removeEventListener(NATIVE_SOCKET_OPEN_EVENT, reportActualCodeSurfaceReady);
    observer.disconnect();
  };
  stopReadinessWatch = cleanup;
  observer.observe(root, {
    attributeFilter: ["aria-disabled", "disabled"],
    attributes: true,
    childList: true,
    subtree: true,
  });
  window.addEventListener(NATIVE_SOCKET_OPEN_EVENT, reportActualCodeSurfaceReady);
  reportActualCodeSurfaceReady();
}

function isNativeHTTPURL(value: string): boolean {
  try {
    const url = new URL(value);
    return url.origin === HTTP_ORIGIN;
  } catch {
    return false;
  }
}

function isNativeWebSocketURL(value: string): boolean {
  try {
    const url = new URL(value);
    return url.origin === WEBSOCKET_ORIGIN;
  } catch {
    return false;
  }
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function ownedArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const owned = new Uint8Array(bytes.byteLength);
  owned.set(bytes);
  return owned.buffer;
}

async function requestBodyBase64(request: Request): Promise<string | undefined> {
  if (request.method === "GET" || request.method === "HEAD") return undefined;
  const body = await request.clone().arrayBuffer();
  return body.byteLength === 0 ? undefined : bytesToBase64(new Uint8Array(body));
}

export function installNativeFetch(originalFetch: FetchLike): typeof globalThis.fetch {
  const bridgedFetch = async (
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<Response> => {
    const candidateURL =
      input instanceof Request ? input.url : input instanceof URL ? input.href : String(input);
    if (!isNativeHTTPURL(candidateURL)) {
      return originalFetch(input, init);
    }

    const request = new Request(input, init);
    const headers: Record<string, string> = {};
    request.headers.forEach((value, name) => {
      headers[name] = value;
    });
    const response = (await nativeHandler().postMessage({
      type: "fetch",
      request: {
        bodyBase64: await requestBodyBase64(request),
        headers,
        method: request.method,
        url: request.url,
      },
    })) as NativeFetchResponse;
    const body = base64ToBytes(response.bodyBase64);
    return new Response(ownedArrayBuffer(body), {
      headers: response.headers,
      status: response.status,
      statusText: response.statusText,
    });
  };
  return Object.assign(bridgedFetch, {
    preconnect: originalFetch.preconnect ?? (() => undefined),
  });
}

type SocketEventHandler<T extends Event> = ((this: WebSocket, event: T) => unknown) | null;

class NativeWebSocket extends EventTarget {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;

  readonly CONNECTING = 0;
  readonly OPEN = 1;
  readonly CLOSING = 2;
  readonly CLOSED = 3;

  binaryType: BinaryType = "blob";
  bufferedAmount = 0;
  extensions = "";
  onclose: SocketEventHandler<CloseEvent> = null;
  onerror: SocketEventHandler<Event> = null;
  onmessage: SocketEventHandler<MessageEvent> = null;
  onopen: SocketEventHandler<Event> = null;
  protocol = "";
  readyState = NativeWebSocket.CONNECTING;
  readonly url: string;

  readonly #id = crypto.randomUUID();
  readonly #protocols: string[];

  constructor(url: string | URL, protocols?: string | string[]) {
    super();
    this.url = String(url);
    this.#protocols =
      typeof protocols === "string" ? [protocols] : protocols === undefined ? [] : [...protocols];
    socketRegistry.set(this.#id, this);
    void ensureCodeMounted()
      .then(() =>
        nativeHandler().postMessage({
          id: this.#id,
          protocols: this.#protocols,
          type: "websocketOpen",
          url: this.url,
        }),
      )
      .catch(() => this.failOpening());
  }

  send(data: string | ArrayBufferLike | Blob | ArrayBufferView): void {
    if (this.readyState !== NativeWebSocket.OPEN) {
      throw new DOMException("WebSocket is not open", "InvalidStateError");
    }
    let kind: "text" | "binary";
    let payload: string;
    if (typeof data === "string") {
      kind = "text";
      payload = data;
    } else if (data instanceof ArrayBuffer) {
      kind = "binary";
      payload = bytesToBase64(new Uint8Array(data));
    } else if (ArrayBuffer.isView(data)) {
      kind = "binary";
      payload = bytesToBase64(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
    } else {
      throw new DOMException("Blob WebSocket messages are unsupported", "NotSupportedError");
    }
    void nativeHandler()
      .postMessage({ id: this.#id, kind, payload, type: "websocketSend" })
      .catch(() => this.receive({ id: this.#id, type: "error" }));
  }

  close(code = 1000, reason = ""): void {
    if (this.readyState === NativeWebSocket.CLOSED) return;
    if (this.readyState === NativeWebSocket.CLOSING) return;
    this.readyState = NativeWebSocket.CLOSING;
    void nativeHandler()
      .postMessage({ code, id: this.#id, reason, type: "websocketClose" })
      .catch(() =>
        this.receive({
          code: 1006,
          id: this.#id,
          reason: "",
          type: "close",
          wasClean: false,
        }),
      );
  }

  receive(event: NativeSocketEvent): void {
    switch (event.type) {
      case "open": {
        if (this.readyState !== NativeWebSocket.CONNECTING) return;
        this.protocol = event.protocol;
        this.readyState = NativeWebSocket.OPEN;
        markNativeCodeSocketOpened();
        const opened = new Event("open");
        this.dispatchEvent(opened);
        this.onopen?.call(this as unknown as WebSocket, opened);
        break;
      }
      case "message": {
        if (this.readyState !== NativeWebSocket.OPEN) return;
        const bytes = event.kind === "binary" ? base64ToBytes(event.payload) : null;
        const data =
          bytes === null
            ? event.payload
            : this.binaryType === "arraybuffer"
              ? ownedArrayBuffer(bytes)
              : new Blob([ownedArrayBuffer(bytes)]);
        const message = new MessageEvent("message", { data });
        this.dispatchEvent(message);
        this.onmessage?.call(this as unknown as WebSocket, message);
        break;
      }
      case "error": {
        const error = new Event("error");
        this.dispatchEvent(error);
        this.onerror?.call(this as unknown as WebSocket, error);
        break;
      }
      case "close": {
        if (this.readyState === NativeWebSocket.CLOSED) return;
        this.readyState = NativeWebSocket.CLOSED;
        socketRegistry.delete(this.#id);
        markNativeCodeSocketClosed();
        const closed = new CloseEvent("close", {
          code: event.code,
          reason: event.reason,
          wasClean: event.wasClean,
        });
        this.dispatchEvent(closed);
        this.onclose?.call(this as unknown as WebSocket, closed);
        break;
      }
    }
  }

  private failOpening(): void {
    this.receive({ id: this.#id, type: "error" });
    this.receive({
      code: 1006,
      id: this.#id,
      reason: "",
      type: "close",
      wasClean: false,
    });
  }
}

const socketRegistry = new Map<string, NativeWebSocket>();

export function installNativeWebSocket(originalWebSocket: typeof WebSocket): typeof WebSocket {
  return new Proxy(originalWebSocket, {
    construct(target, argumentsList) {
      const [rawURL, protocols] = argumentsList as [string | URL, string | string[] | undefined];
      if (!isNativeWebSocketURL(String(rawURL))) {
        return Reflect.construct(target, argumentsList);
      }
      return new NativeWebSocket(rawURL, protocols);
    },
  }) as typeof WebSocket;
}

function readPersistedJSON(key: string): unknown | null {
  try {
    const value = window.localStorage.getItem(key);
    return value === null ? null : JSON.parse(value);
  } catch {
    return null;
  }
}

function writePersistedJSON(key: string, value: unknown): void {
  window.localStorage.setItem(key, JSON.stringify(value));
}

function unsupportedDesktopOperation(): Promise<never> {
  return Promise.reject(new Error("This desktop operation is unavailable in cmux"));
}

function updateState() {
  return {
    appArch: "arm64",
    availableVersion: null,
    canRetry: false,
    checkedAt: null,
    channel: "latest",
    currentVersion: "",
    downloadPercent: null,
    downloadedVersion: null,
    enabled: false,
    errorContext: null,
    hostArch: "arm64",
    message: null,
    releaseNotes: [],
    runningUnderArm64Translation: false,
    status: "disabled",
  };
}

export function createDesktopBridge() {
  const wslState = {
    available: false,
    distro: null,
    distros: [],
    enabled: false,
    preflightError: null,
    wslOnly: false,
  };
  const exposureState = {
    advertisedHost: null,
    endpointUrl: null,
    mode: "local-only",
    tailscaleServeEnabled: false,
    tailscaleServePort: 443,
  };
  return {
    bootstrapSshBearerSession: unsupportedDesktopOperation,
    checkForUpdate: async () => ({ checked: false, state: updateState() }),
    clearConnectionCatalog: async () => window.localStorage.removeItem(CONNECTION_CATALOG_KEY),
    confirm: async (message: string) => window.confirm(message),
    disconnectSshEnvironment: unsupportedDesktopOperation,
    discoverSshHosts: async () => [],
    downloadUpdate: async () => ({ accepted: false, completed: false, state: updateState() }),
    ensureSshEnvironment: unsupportedDesktopOperation,
    fetchSshEnvironmentDescriptor: unsupportedDesktopOperation,
    fetchSshSessionState: unsupportedDesktopOperation,
    getAdvertisedEndpoints: async () => [],
    getAppBranding: () => ({ baseName: "Code", displayName: "Code", stageLabel: "Alpha" }),
    getClientSettings: async () => readPersistedJSON(CLIENT_SETTINGS_KEY),
    getConnectionCatalog: async () => window.localStorage.getItem(CONNECTION_CATALOG_KEY),
    getLocalEnvironmentBearerToken: async () => {
      await ensureCodeMounted();
      return NATIVE_BEARER_SENTINEL;
    },
    getLocalEnvironmentBootstraps: () => [
      {
        httpBaseUrl: `${HTTP_ORIGIN}/`,
        id: "primary",
        label: "Local environment",
        wsBaseUrl: `${WEBSOCKET_ORIGIN}/`,
      },
    ],
    getServerExposureState: async () => exposureState,
    getUpdateState: async () => updateState(),
    getWindowFullscreenState: () => document.fullscreenElement !== null,
    getWslState: async () => wslState,
    installUpdate: async () => ({ accepted: false, completed: false, state: updateState() }),
    issueSshWebSocketTicket: unsupportedDesktopOperation,
    onMenuAction: () => () => undefined,
    onSshPasswordPrompt: () => () => undefined,
    onUpdateState: () => () => undefined,
    onWindowFullscreenStateChange: () => () => undefined,
    openExternal: async (url: string) => {
      const target = new URL(url);
      if (target.protocol !== "http:" && target.protocol !== "https:") return false;
      window.open(target.href, "_blank", "noopener,noreferrer");
      return true;
    },
    pickFolder: async () => null,
    resolveSshPasswordPrompt: unsupportedDesktopOperation,
    setClientSettings: async (settings: unknown) => writePersistedJSON(CLIENT_SETTINGS_KEY, settings),
    setConnectionCatalog: async (catalog: string) => {
      window.localStorage.setItem(CONNECTION_CATALOG_KEY, catalog);
      return true;
    },
    setServerExposureMode: async () => exposureState,
    setTailscaleServeEnabled: async () => exposureState,
    setTheme: async () => undefined,
    setUpdateChannel: async () => updateState(),
    setWslBackendEnabled: async () => wslState,
    setWslDistro: async () => wslState,
    setWslOnly: async () => wslState,
    showContextMenu: async () => null,
  };
}

export function installCodeBridge(): CmuxCodeBridge {
  if (installedBridge) return installedBridge;
  const bridge: CmuxCodeBridge = {
    mount: ensureCodeMounted,
    stopPrewarmHealthMonitoring() {
      stopReadinessWatch?.();
      stopReadinessWatch = null;
    },
    __receiveSocketEvent(event) {
      socketRegistry.get(event.id)?.receive(event);
    },
  };
  installedBridge = bridge;
  window.cmuxCode = bridge;
  window.desktopBridge = createDesktopBridge();
  originalGlobalFetch ??= globalThis.fetch;
  originalGlobalWebSocket ??= globalThis.WebSocket;
  globalThis.fetch = installNativeFetch(globalThis.fetch);
  globalThis.WebSocket = installNativeWebSocket(globalThis.WebSocket);
  watchForActualCodeSurfaceReadiness();
  void ensureCodeMounted().catch(() => undefined);
  return bridge;
}

if (typeof window !== "undefined") {
  installCodeBridge();
}
