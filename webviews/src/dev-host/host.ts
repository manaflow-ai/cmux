// Browser-only host for the cmux-next web development loop. This file is imported by the Vite
// dev entry, never by the shipped pane entry. It keeps the native bridge shape while letting the
// real pane transport use the local acpmux WebSocket directly.

export type DevHostParams = {
  endpoint: string;
  token: string;
  sessionId?: string;
  newSession?: boolean;
  cwd?: string;
  editorOrigin?: string;
};

type Request = { id: string; method: string; params?: Record<string, unknown> };
export type DevHostReply =
  | { ok: true; value: unknown }
  | { ok: false; error: { code: string; message: string; origin: string } };

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
    cwd: params.get("cwd") ?? undefined,
    editorOrigin,
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

function openFile(host: DevHostParams, params: Record<string, unknown> | undefined): DevHostReply {
  const path = typeof params?.path === "string" ? params.path : "";
  if (!path) return unsupported("file.open");
  const url = editorURL(host, path);
  if (typeof window.open === "function") window.open(url, "_blank", "noopener");
  else console.info("cmux dev file.open", path);
  return { ok: true, value: { path, url } };
}

function safeReadResult(host: DevHostParams, params: Record<string, unknown> | undefined): unknown {
  const root = typeof params?.path === "string" ? params.path : (host.cwd ?? ".");
  return { root, search_root: root, results: [], truncated: false };
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
export function devHostReply(host: DevHostParams, request: Request): DevHostReply {
  const method = request.method.replace(/^cmux\.agent\./, "");
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
          cwd: host.cwd,
          linkScheme: "cmux-dev",
        },
      };
    case "session.persist":
    case "chat.persistSession":
    case "pane.painted":
    case "pane.checkpointAvailability":
    case "pane.renderRate":
    case "newTab.remember":
    case "newTab.touched":
    case "shortcut.edit":
    case "tab.jump":
    case "tab.open":
    case "action.run":
    case "onboarding.importAndSync":
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
    case "file.search":
      return { ok: true, value: safeReadResult(host, request.params) };
    case "git.status":
      return {
        ok: true,
        value: { root: host.cwd ?? ".", detached: false, branch: "dev", ahead: 0, behind: 0 },
      };
    case "git.diff":
    case "git.checkpoint.diff":
      return {
        ok: true,
        value: {
          root: host.cwd ?? ".",
          files: [],
          additions: 0,
          deletions: 0,
          total_files: 0,
          files_omitted: 0,
        },
      };
    case "acp.trust.get":
      return { ok: true, value: { cwd: request.params?.cwd ?? host.cwd, level: "unknown" } };
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

function pageReply(host: DevHostParams, message: unknown): unknown {
  if (!message || typeof message !== "object") return message;
  const envelope = message as { t?: string; id?: number; op?: string; params?: Record<string, unknown> };
  if (envelope.t === "call" && typeof envelope.id === "number") {
    const reply = devHostReply(host, {
      id: String(envelope.id),
      method: envelope.op ?? "",
      params: envelope.params,
    });
    return reply.ok
      ? { t: "ok", id: envelope.id, value: reply.value }
      : { t: "err", id: envelope.id, code: reply.error.code, message: reply.error.message };
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
    handlers.cmuxPage = { postMessage: (message: unknown) => Promise.resolve(pageReply(host, message)) };
  }
  window.webkit = { ...current, messageHandlers: handlers } as Window["webkit"];
}
