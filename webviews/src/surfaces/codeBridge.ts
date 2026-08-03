const HTTP_ORIGIN = "https://cmux-code.invalid";
const WEBSOCKET_ORIGIN = "wss://cmux-code.invalid";
const NATIVE_BEARER_SENTINEL = "cmux-native";
const CLIENT_SETTINGS_KEY = "cmux:code-client-settings";
const CONNECTION_CATALOG_KEY = "cmux:code-connection-catalog";
const NATIVE_SOCKET_OPEN_EVENT = "cmux-code-native-socket-open";
const LIVE_LAYOUT_SETTLE_DELAY_MS = 100;
const LIVE_LAYOUT_NO_SOCKET_FALLBACK_DELAY_MS = 5_000;
const LIVE_LAYOUT_ERROR_FALLBACK_DELAY_MS = 30_000;

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
  __receiveSocketEvent(event: NativeSocketEvent): void;
}

interface CodeStaticBootstrap {
  strings?: Record<string, string>;
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
let runtimeAssetsActivated = false;
let originalGlobalFetch: typeof globalThis.fetch | null = null;
let originalGlobalWebSocket: typeof globalThis.WebSocket | null = null;
let nativeSocketHasOpened = false;

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
  runtimeAssetsActivated = false;
  socketRegistry.clear();
  if (originalGlobalFetch) globalThis.fetch = originalGlobalFetch;
  if (originalGlobalWebSocket) globalThis.WebSocket = originalGlobalWebSocket;
  originalGlobalFetch = null;
  originalGlobalWebSocket = null;
  nativeSocketHasOpened = false;
}

function setNativeTextAreaValue(textarea: HTMLTextAreaElement, value: string): void {
  const descriptor = Object.getOwnPropertyDescriptor(
    window.HTMLTextAreaElement.prototype,
    "value",
  );
  descriptor?.set?.call(textarea, value);
  textarea.dispatchEvent(new window.Event("input", { bubbles: true }));
}

function setAppComposerValue(composer: HTMLElement, value: string): void {
  if (composer instanceof window.HTMLTextAreaElement) {
    setNativeTextAreaValue(composer, value);
    return;
  }
  composer.focus();
  const inserted = window.document.execCommand?.("insertText", false, value) ?? false;
  if (inserted) return;
  composer.textContent = value;
  composer.dispatchEvent(
    new window.InputEvent("input", {
      bubbles: true,
      data: value,
      inputType: "insertText",
    }),
  );
}

function hasRenderedAppComposer(root: HTMLElement | null): boolean {
  return Boolean(
    root?.querySelector('[data-slot="sidebar-wrapper"]') &&
      root.querySelector('textarea:not([disabled]), [contenteditable="true"][role="textbox"]'),
  );
}

export function markNativeCodeSocketOpened(): void {
  if (nativeSocketHasOpened) return;
  nativeSocketHasOpened = true;
  window.dispatchEvent(new window.Event(NATIVE_SOCKET_OPEN_EVENT));
}

export function dismissBootShellWhenAppRenders(
  forceTransientAlert = false,
  requireNativeSocket = false,
): boolean {
  const shell = window.document.getElementById("boot-shell");
  const root = window.document.getElementById("root");
  const appLayout = root?.querySelector('[data-slot="sidebar-wrapper"]');
  const appComposer = root?.querySelector<HTMLElement>(
    'textarea:not([disabled]), [contenteditable="true"][role="textbox"]',
  );
  if (!shell || !appLayout || !appComposer) return false;
  if (requireNativeSocket && !nativeSocketHasOpened) return false;
  if (!forceTransientAlert && root?.querySelector('[role="alert"] button:disabled')) return false;

  const instantComposer = shell.querySelector<HTMLTextAreaElement>("#cmux-code-instant-draft");
  const shouldRestoreFocus = window.document.activeElement === instantComposer;
  const pendingSubmit = shell.dataset.cmuxPendingSubmit === "true";
  if (instantComposer?.value) {
    setAppComposerValue(appComposer, instantComposer.value);
  }
  shell.remove();
  if (shouldRestoreFocus) appComposer.focus();
  if (pendingSubmit) {
    window.requestAnimationFrame(() => {
      appComposer.dispatchEvent(
        new window.KeyboardEvent("keydown", {
          bubbles: true,
          cancelable: true,
          code: "Enter",
          key: "Enter",
        }),
      );
    });
  }
  return true;
}

export function prepareInstantCodeSurface(): boolean {
  const shell = window.document.getElementById("boot-shell");
  if (!shell || shell.dataset.cmuxPrepared === "true") return false;

  const bootstrap = window.__cmuxCodeStaticBootstrap as CodeStaticBootstrap | undefined;
  for (const element of shell.querySelectorAll<HTMLElement>("[data-cmux-string]")) {
    const key = element.dataset.cmuxString;
    if (key && bootstrap?.strings?.[key]) element.textContent = bootstrap.strings[key];
  }
  for (const element of shell.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>(
    "[data-cmux-placeholder]",
  )) {
    const key = element.dataset.cmuxPlaceholder;
    if (key && bootstrap?.strings?.[key]) element.placeholder = bootstrap.strings[key];
  }
  for (const element of shell.querySelectorAll<HTMLElement>("[data-cmux-aria-label]")) {
    const key = element.dataset.cmuxAriaLabel;
    if (key && bootstrap?.strings?.[key]) {
      element.setAttribute("aria-label", bootstrap.strings[key]);
    }
  }

  shell.querySelector("form")?.addEventListener("submit", (event) => {
    event.preventDefault();
    shell.dataset.cmuxPendingSubmit = "true";
  });
  shell.dataset.cmuxPrepared = "true";
  window.performance?.mark?.("cmux-code-static-ready");
  return true;
}

function watchForRenderedApp(): void {
  const root = window.document.getElementById("root");
  if (!root) {
    window.document.addEventListener("DOMContentLoaded", watchForRenderedApp, { once: true });
    return;
  }
  let settleTimer: number | undefined;
  let noSocketFallbackTimer: number | undefined;
  let errorFallbackTimer: number | undefined;
  const observer = new window.MutationObserver(scheduleSettledCheck);
  const cleanup = () => {
    if (settleTimer !== undefined) window.clearTimeout(settleTimer);
    if (noSocketFallbackTimer !== undefined) window.clearTimeout(noSocketFallbackTimer);
    if (errorFallbackTimer !== undefined) window.clearTimeout(errorFallbackTimer);
    window.removeEventListener(NATIVE_SOCKET_OPEN_EVENT, scheduleSettledCheck);
    observer.disconnect();
  };
  const attemptDismissal = (forceTransientAlert: boolean, requireNativeSocket: boolean) => {
    if (!dismissBootShellWhenAppRenders(forceTransientAlert, requireNativeSocket)) return false;
    cleanup();
    return true;
  };
  function scheduleSettledCheck(): void {
    if (noSocketFallbackTimer === undefined && hasRenderedAppComposer(root)) {
      noSocketFallbackTimer = window.setTimeout(() => {
        noSocketFallbackTimer = undefined;
        attemptDismissal(false, false);
      }, LIVE_LAYOUT_NO_SOCKET_FALLBACK_DELAY_MS);
      errorFallbackTimer = window.setTimeout(() => {
        errorFallbackTimer = undefined;
        attemptDismissal(true, false);
      }, LIVE_LAYOUT_ERROR_FALLBACK_DELAY_MS);
    }
    if (settleTimer !== undefined) window.clearTimeout(settleTimer);
    settleTimer = window.setTimeout(() => {
      settleTimer = undefined;
      attemptDismissal(false, true);
    }, LIVE_LAYOUT_SETTLE_DELAY_MS);
  }
  observer.observe(root, {
    attributeFilter: ["disabled"],
    attributes: true,
    childList: true,
    subtree: true,
  });
  window.addEventListener(NATIVE_SOCKET_OPEN_EVENT, scheduleSettledCheck);
  scheduleSettledCheck();
}

export function loadCodeRuntimeAssets(): boolean {
  if (runtimeAssetsActivated) return false;
  const moduleMarker = window.document.querySelector<HTMLScriptElement>(
    'script[type="application/x-cmux-code-module"][data-cmux-code-main]',
  );
  const moduleSource = moduleMarker?.dataset.cmuxCodeMain;
  if (!moduleSource) return false;
  runtimeAssetsActivated = true;

  for (const stylesheet of window.document.querySelectorAll<HTMLLinkElement>(
    "link[data-cmux-code-stylesheet]",
  )) {
    stylesheet.rel = "stylesheet";
    stylesheet.crossOrigin = "anonymous";
  }
  for (const preload of window.document.querySelectorAll<HTMLLinkElement>(
    "link[data-cmux-code-modulepreload]",
  )) {
    preload.rel = "modulepreload";
    preload.crossOrigin = "anonymous";
  }

  const module = window.document.createElement("script");
  module.type = "module";
  module.crossOrigin = "anonymous";
  module.src = moduleSource;
  module.dataset.cmuxCodeRuntime = "true";
  moduleMarker.replaceWith(module);
  return true;
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
  watchForRenderedApp();
  void ensureCodeMounted().catch(() => undefined);
  return bridge;
}

export function activateCodeSurface(): CmuxCodeBridge {
  window.performance?.mark?.("cmux-code-activated");
  const bridge = installCodeBridge();
  loadCodeRuntimeAssets();
  return bridge;
}

export function finishCodeDocumentBootstrap(): void {
  prepareInstantCodeSurface();
  if (window.__cmuxCodeAutoActivate === true) activateCodeSurface();
}

if (typeof window !== "undefined") {
  window.__cmuxActivateCodeSurface = activateCodeSurface;
  if (window.document.readyState === "loading") {
    // The bridge script precedes the inert runtime marker in the generated
    // document. Wait for parsing to finish so a cold visible web view can
    // find and activate that marker on its first pass.
    window.document.addEventListener("DOMContentLoaded", finishCodeDocumentBootstrap, {
      once: true,
    });
  } else {
    finishCodeDocumentBootstrap();
  }
}
