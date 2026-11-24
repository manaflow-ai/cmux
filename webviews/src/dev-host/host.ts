// Browser-only host for the cmux-next web development loop. This file is imported by the Vite
// dev entry, never by the shipped pane entry. It keeps the native bridge shape while letting the
// real pane transport use the local acpmux WebSocket directly.
import { noteChatTheme } from "../agent-session/acpmux/chatSnapshot/live";

export type DevHostParams = {
  endpoint: string;
  token: string;
  sessionId?: string;
  /// `#sessions=a,b,…` (with `?mounts=N`, mountModel.tsx): each pane in the document takes the next chat on its first
  /// `ready`, so one document holds several chats (bench/chat-pages-memory.bench.ts SHARED=1).
  sessions?: string[];
  newSession?: boolean;
  /// `#newtab`: the pane opens as a New Tab page, as a tab the app opened for one does.
  newTab?: boolean;
  cwd?: string;
  editorOrigin?: string;
  /// An explicit session binds the tab to that chat. Older links can also pass `#must`.
  sessionMustExist?: boolean;
  /// `#machine=…`: the machine the app names the chat's (`machineName`), for the composer and the
  /// unavailable state.
  machineName?: string;
  /// `#scheme=…`: the link scheme the handshake names (default `cmux-dev`). The benches pass a shipped
  /// build's (`cmux`), so their page runs what ships: a `cmux-dev` scheme turns on the dev-only
  /// layout-motion audit (devMotionAudit.ts), which asks for a frame on every DOM change.
  linkScheme?: string;
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
    sessions: params.get("sessions")?.split(",").filter(Boolean),
    newSession: params.has("new") || undefined,
    newTab: params.has("newtab") || undefined,
    cwd: params.get("cwd") ?? undefined,
    editorOrigin,
    sessionMustExist: Boolean(params.get("session")) || params.has("must") || undefined,
    machineName: params.get("machine") ?? undefined,
    linkScheme: params.get("scheme") ?? undefined,
  };
}

type DevHostKept = {
  tails: Record<string, unknown>;
  anchors: Record<string, unknown>;
  /// Each chat's drawn copy (`chat.snapshot.put`), which a test serves to the next page as the
  /// app's `__snapshot/chat.js` does.
  snapshots?: Record<string, unknown>;
};

/// The app host's per-chat tails and reading places, in this page (`cmuxDevHostKept`).
function keptReply(method: string, params: Record<string, unknown>): DevHostReply {
  const kept = (globalThis as { cmuxDevHostKept?: DevHostKept }).cmuxDevHostKept;
  if (!kept) return unsupported(method);
  const sessionId = String(params.sessionId ?? "");
  switch (method) {
    case "chat.tail":
      if (params.tail === undefined) delete kept.tails[sessionId];
      else kept.tails[sessionId] = params.tail;
      return { ok: true, value: null };
    case "chat.tail.get":
      return { ok: true, value: kept.tails[sessionId] ?? null };
    case "chat.snapshot.put": {
      // As the app keeps it: a copy whole, a miss as its reason and the composer's prompt.
      const { sessionId: _chat, ...snapshot } = params;
      const held = typeof snapshot.html === "string" ? snapshot : { miss: snapshot.miss, draft: snapshot.draft };
      kept.snapshots = { ...kept.snapshots, [sessionId]: held };
      return { ok: true, value: { kept: true } };
    }
    case "chat.snapshot.get": {
      const held = kept.snapshots?.[sessionId] as { html?: unknown } | undefined;
      return { ok: true, value: typeof held?.html === "string" ? held : null };
    }
    case "chat.scrollAnchor":
      kept.anchors[sessionId] = { rowId: params.rowId, offset: params.offset };
      return { ok: true, value: null };
    default:
      return { ok: true, value: kept.anchors[sessionId] ?? null };
  }
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
    case "ready": {
      const next = request.params?.reconnect ? undefined : host.sessions?.shift();
      if (next) host.sessionId = next;
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
          linkScheme: host.linkScheme ?? "cmux-dev",
          ...(host.sessionMustExist ? { sessionMustExist: true } : {}),
          ...(host.machineName ? { machineName: host.machineName } : {}),
        },
      };
    }
    case "pane.action": {
      // The app's tab actions (close, split, …) have no tab here: kept for the page's tests.
      const actions = ((globalThis as { cmuxDevPaneActions?: string[] }).cmuxDevPaneActions ??= []);
      actions.push(String(request.params?.id ?? ""));
      return { ok: true, value: null };
    }
    case "cmux.page.heartbeat":
      // As the app's page host answers (PageWebView takesRestBeats): a page with nothing happening in it
      // stops beating after 10 s (pageHealth.ts). "Unsupported" here kept every dev and bench page beating
      // every 2 s for good, a wakeup the app does not have.
      return { ok: true, value: { rest: true } };
    case "pane.painted":
      // When the app would fade the page in over its loading state (frame tests read it).
      (window as { cmuxDevPaintedAt?: number }).cmuxDevPaintedAt ??= performance.now();
      return { ok: true, value: null };
    case "session.persist":
    case "chat.persistSession": {
      // The tab now records this chat, as the app's tab does: a later handshake (a reconnect to a
      // restarted daemon) names it instead of the New Tab the page opened as.
      const persisted = request.params?.sessionId;
      if (typeof persisted === "string" && persisted) {
        host.sessionId = persisted;
        host.newSession = undefined;
        host.newTab = undefined;
      }
      // As slow as the app's answer can be, for frame tests (`cmuxDevPersistMs`): a send's row must
      // never wait on it in a started chat.
      const ms = (window as { cmuxDevPersistMs?: number }).cmuxDevPersistMs;
      return ms
        ? new Promise((resolve) => setTimeout(() => resolve({ ok: true, value: null }), ms))
        : { ok: true, value: null };
    }
    case "pane.checkpointAvailability":
    case "pane.commandAvailability":
    case "pane.clientReady":
    case "pane.renderRate":
    case "pane.launchSettle":
    case "pane.tabRowTools":
    case "newTab.remember":
    case "newTab.setTemplate":
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
    // What the app host keeps of a chat for its next page (tailCache.ts, App.tsx's reading place),
    // only on a page a test gave `cmuxDevHostKept`: it hands that to a new page to open it as after
    // an app restart (agent-pane-settled-load.test.ts). Other pages keep no host copy, as before.
    case "chat.tail":
    case "chat.tail.get":
    case "chat.scrollAnchor":
    case "chat.scrollAnchor.get":
    case "chat.snapshot.put":
    case "chat.snapshot.get":
      return keptReply(method, request.params ?? {});
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
  // A page that keeps what the host keeps writes its drawn copy too: the app keys one by the theme
  // its `theme` event names, which this host sends none of.
  if ((globalThis as { cmuxDevHostKept?: unknown }).cmuxDevHostKept) noteChatTheme("dev-host");
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
