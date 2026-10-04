// Dev server only (dev.tsx): stands in for Swift's `agentSession` message handler so the pane runs
// in a plain browser against a standalone `acpmux daemon run`. The daemon's endpoint and token come
// from the URL fragment (`#endpoint=ws://127.0.0.1:<port>/&token=<token>`), which the browser never
// sends to the dev server. `scripts/agent-pane/dev-slot.sh` starts a daemon and prints that URL.
// Native-only requests (git, files, tabs, dictation) are refused as `native.unsupported`.

type DevHostParams = {
  endpoint: string;
  token: string;
  sessionId?: string;
  newSession?: boolean;
  cwd?: string;
};

/// The standalone daemon named by `hash`, or undefined when the fragment names none.
export function devHostParams(hash: string): DevHostParams | undefined {
  const params = new URLSearchParams(hash.replace(/^#/, ""));
  const endpoint = params.get("endpoint");
  const token = params.get("token");
  if (!endpoint || !token) return undefined;
  const url = URL.canParse(endpoint) ? new URL(endpoint) : undefined;
  if (url?.protocol !== "ws:" || !["127.0.0.1", "localhost"].includes(url.hostname)) return undefined;
  return {
    endpoint,
    token,
    sessionId: params.get("session") ?? undefined,
    newSession: params.has("new") || undefined,
    cwd: params.get("cwd") ?? undefined,
  };
}

type Request = { id: string; method: string; params?: Record<string, unknown> };
type Reply = { ok: true; value: unknown } | { ok: false; error: { code: string; message: string; origin: string } };

/// Answers the requests Swift's AgentPaneRequest would, for the ones a browser can.
export function devHostReply(host: DevHostParams, request: Request): Reply {
  switch (request.method) {
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
    case "chat.persistSession":
      return { ok: true, value: null };
    case "browser.open": {
      const url = String(request.params?.url ?? "");
      if (URL.canParse(url)) window.open(url, "_blank", "noopener");
      return { ok: true, value: null };
    }
    default:
      return {
        ok: false,
        error: {
          code: "native.unsupported",
          message: `${request.method} needs the cmux host`,
          origin: "native",
        },
      };
  }
}

/// Installs the stand-in handler. Never replaces a real host.
export function installDevHost(host: DevHostParams): void {
  if (window.webkit?.messageHandlers?.agentSession) return;
  const agentSession = { postMessage: (request: Request) => Promise.resolve(devHostReply(host, request)) };
  const webkit = (window.webkit ?? {}) as NonNullable<Window["webkit"]>;
  window.webkit = { ...webkit, messageHandlers: { ...webkit.messageHandlers, agentSession } } as Window["webkit"];
}
