// Browser-only host for the cmux-next web development loop. This file is imported by the Vite
// dev entry, never by the shipped pane entry. It keeps the native bridge shape while letting the
// real pane transport use the local acpmux WebSocket directly.

export type DevHostParams = {
  endpoint: string;
  token: string;
  sessionId?: string;
  newSession?: boolean;
  /// `#newtab`: the pane opens as a New Tab page, as a tab the app opened for one does.
  newTab?: boolean;
  cwd?: string;
  editorOrigin?: string;
  /// `#must`: the tab's recorded session must exist (the app's `sessionMustExist`), so a session
  /// the daemon lacks shows the pane's unavailable state instead of another chat.
  sessionMustExist?: boolean;
  /// `#machine=…`: the machine the app names the chat's (`machineName`), for the composer and the
  /// unavailable state.
  machineName?: string;
};

type Request = { id: string; method: string; params?: Record<string, unknown> };
export type DevHostReply =
  | { ok: true; value: unknown }
  | {
      ok: false;
      error: { code: string; message: string; origin: string; userMessage?: string; details?: unknown };
    };

/// The reads the dev server answers from the slot's folder (dev-server/agentGitHost.ts).
const SERVED_READS = new Set(["git.status", "git.diff", "git.checkpoint.diff", "file.search"]);

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]"]);
let gestureSequence = 0;
let lastGestureAt = 0;
let gesturesInstalled = false;

/** Reads and validates the daemon connection carried in the page fragment. */
export function devHostParams(hash: string): DevHostParams | undefined {
  const params = new URLSearchParams(hash.replace(/^#/, ""));
  const endpoint = params.get("endpoint");
  const token = params.get("token");
  if (!endpoint || !token) return undefined;
  const url = URL.canParse(endpoint) ? new URL(endpoint) : undefined;
  if (url?.protocol !== "ws:" || !LOOPBACK_HOSTS.has(url.hostname)) return undefined;
  const editorOrigin = params.get("editor") ?? undefined;
  if (editorOrigin) {
    const editorURL = URL.canParse(editorOrigin) ? new URL(editorOrigin) : undefined;
    if (!editorURL || editorURL.protocol !== "http:" || !LOOPBACK_HOSTS.has(editorURL.hostname)) return undefined;
  }
  return {
    endpoint,
    token,
    sessionId: params.get("session") ?? undefined,
    newSession: params.has("new") || undefined,
    newTab: params.has("newtab") || undefined,
    cwd: params.get("cwd") ?? undefined,
    editorOrigin,
    sessionMustExist: params.has("must") || undefined,
    machineName: params.get("machine") ?? undefined,
  };
}

function unsupported(method: string): DevHostReply {
  return {
    ok: false,
    error: {
      code: "native.unsupported",
      message: `${method} needs the cmux host`,
      origin: "native",
    },
  };
}

function editorURL(host: DevHostParams, path: string): string {
  const origin = host.editorOrigin ?? window.location.origin;
  const url = new URL("/editor", origin);
  url.searchParams.set("file", path);
  return url.toString();
}

/** Normalizes an absolute POSIX path without touching the filesystem. */
function normalizedAbsolutePath(value: string): string | undefined {
  if (!value.startsWith("/")) return undefined;
  const parts: string[] = [];
  for (const part of value.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") {
      if (parts.length === 0) return undefined;
      parts.pop();
    } else parts.push(part);
  }
  return `/${parts.join("/")}`;
}

/** Browser dev may open only files in the checkout named by the daemon link. */
function pathInCheckout(host: DevHostParams, value: string): boolean {
  const root = host.cwd && normalizedAbsolutePath(host.cwd);
  const file = normalizedAbsolutePath(value);
  return Boolean(root && file && (file === root || file.startsWith(`${root}/`)));
}

function openFile(host: DevHostParams, params: Record<string, unknown> | undefined): DevHostReply {
  const path = typeof params?.path === "string" ? params.path : "";
  if (!path || !pathInCheckout(host, path)) return unsupported("file.open");
  const url = editorURL(host, path);
  if (typeof window !== "undefined" && typeof window.open === "function") window.open(url, "_blank", "noopener");
  else console.info("cmux dev file.open", path);
  return { ok: true, value: { path, url } };
}

/// A read the dev server answers for real, from the slot's folder. Without a recorded slot folder
/// the host refuses it instead of reading outside the selected checkout.
async function servedRead(host: DevHostParams, method: string, request: Request): Promise<DevHostReply> {
  const params = { ...request.params, cwd: request.params?.cwd ?? host.cwd };
  let response: Response;
  try {
    response = await fetch("/__dev-host/read", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ method, params }),
    });
  } catch {
    return unsupported(`${method} (start the checkout dev host)`);
  }
  if (response.status === 404) return unsupported(`${method} (start the checkout dev host)`);
  if (!response.ok) return unsupported(method);
  return (await response.json()) as DevHostReply;
}

function gestureReply(): DevHostReply {
  if (Date.now() - lastGestureAt > 1_500)
    return {
      ok: false,
      error: {
        code: "transport.gesture_required",
        message: "Click the choice again to apply it.",
        origin: "native",
      },
    };
  gestureSequence += 1;
  return { ok: true, value: { ticket: `dev-gesture-${gestureSequence}` } };
}

/** Routes the native calls used by the pane to safe browser behavior. */
export function devHostReply(host: DevHostParams, request: Request): DevHostReply | Promise<DevHostReply> {
  const method = request.method.replace(/^cmux\.agent\./, "");
  if (SERVED_READS.has(method)) return servedRead(host, method, request);
  switch (method) {
    case "handshake":
    case "ready":
      return {
        ok: true,
        value: {
          protocolVersion: 1,
          transport: "acpmux-websocket",
          endpoint: host.endpoint,
          token: host.token,
          sessionId: host.sessionId,
          newSession: host.newSession,
          ...(host.newTab ? { newTab: true } : {}),
          cwd: host.cwd,
          linkScheme: "cmux-dev",
          ...(host.sessionMustExist ? { sessionMustExist: true } : {}),
          ...(host.machineName ? { machineName: host.machineName } : {}),
        },
      };
    case "pane.action": {
      // The app's tab actions (close, split, …) have no tab here: kept for the page's tests.
      const actions = ((globalThis as { cmuxDevPaneActions?: string[] }).cmuxDevPaneActions ??= []);
      actions.push(String(request.params?.id ?? ""));
      return { ok: true, value: null };
    }
    case "pane.painted":
      // When the app would fade the page in over its loading state (frame tests read it).
      (window as { cmuxDevPaintedAt?: number }).cmuxDevPaintedAt ??= performance.now();
      return { ok: true, value: null };
    case "session.persist":
    case "chat.persistSession":
    case "pane.checkpointAvailability":
    case "pane.commandAvailability":
    case "pane.clientReady":
    case "pane.renderRate":
    case "pane.tabRowTools":
    case "newTab.remember":
    case "newTab.setTemplate":
    case "newTab.editWidgets":
    case "nowPlaying.command":
    case "newTab.touched":
    case "newTab.warm":
    case "shortcut.edit":
    case "tab.jump":
    case "tab.open":
    case "action.run":
      return { ok: true, value: null };
    case "browser.open": {
      const url = String(request.params?.url ?? "");
      // Only web links: never javascript:, data: or file: from agent output.
      const parsed = URL.canParse(url) ? new URL(url) : undefined;
      if (parsed && ["http:", "https:"].includes(parsed.protocol) && typeof window.open === "function")
        window.open(parsed.toString(), "_blank", "noopener");
      return { ok: true, value: null };
    }
    case "file.open":
    case "link.openPath":
      return openFile(host, request.params);
    // The folder's trust is acpmux's answer, which the pane's own daemon client gives once it is
    // bound (App.tsx registers acp.trust.get on window.cmuxAcpmuxActions). A read before that
    // reaches this host, which can't say: an invented "unknown" drew a Trust card over a folder
    // acpmux trusts until the client's read cleared it, shifting the chat (chat-open-long).
    case "acp.trust.get":
      return unsupported(method);
    case "acp.trust.set":
      return { ok: true, value: { cwd: request.params?.cwd ?? host.cwd, level: request.params?.level ?? "unknown" } };
    case "pane.context":
      return { ok: true, value: { cwd: host.cwd, urls: [] } };
    case "transport.gesture":
      return gestureReply();
    default:
      return unsupported(method);
  }
}

function installGestures(): void {
  if (gesturesInstalled || typeof window === "undefined") return;
  gesturesInstalled = true;
  const mark = () => {
    lastGestureAt = Date.now();
  };
  window.addEventListener("pointerdown", mark, { capture: true, passive: true });
  window.addEventListener("keydown", mark, { capture: true, passive: true });
}

async function pageReply(host: DevHostParams, message: unknown): Promise<unknown> {
  if (!message || typeof message !== "object") return message;
  const envelope = message as { t?: string; id?: number; op?: string; params?: Record<string, unknown> };
  if (envelope.t === "call" && typeof envelope.id === "number") {
    const reply = await devHostReply(host, {
      id: String(envelope.id),
      method: envelope.op ?? "",
      params: envelope.params,
    });
    return reply.ok
      ? { t: "ok", id: envelope.id, value: reply.value }
      : {
          t: "err",
          id: envelope.id,
          code: reply.error.code,
          message: reply.error.userMessage ?? reply.error.message,
          details: { origin: reply.error.origin, details: reply.error.details },
        };
  }
  if ((envelope.t === "sub" || envelope.t === "unsub") && typeof envelope.id === "number")
    return { t: "ok", id: envelope.id, value: null };
  return { t: "ok", id: envelope.id, value: null };
}

/** Installs the browser's agentSession and page-host shims without replacing a native host. */
export function installDevHost(host: DevHostParams): void {
  if (typeof window === "undefined") return;
  installGestures();
  const current = (window.webkit ?? {}) as NonNullable<Window["webkit"]>;
  const handlers = (current.messageHandlers ?? {}) as Record<string, unknown>;
  if (!handlers.agentSession) {
    handlers.agentSession = { postMessage: (request: Request) => Promise.resolve(devHostReply(host, request)) };
  }
  if (!handlers.cmuxPage) {
    handlers.cmuxPage = { postMessage: (message: unknown) => pageReply(host, message) };
  }
  window.webkit = { ...current, messageHandlers: handlers } as Window["webkit"];
}
