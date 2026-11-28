// The listener serves the same pane as the app. It supplies the listener token in the
// fragment so it never reaches the HTTP server. Only this origin can receive either proof.
import { followBrowserTheme } from "../../guest/theme";
import { setNativeHost } from "../native";
import { installBrowserNavigation, type BrowserChatRoute } from "../../browser/routes";

export function isBrowserPane(url: URL): boolean {
  return (
    (url.protocol === "https:" || url.protocol === "http:") &&
    (url.pathname === "/app/" || url.pathname === "/app/index.html")
  );
}

/** `acpmux web --app` mints a token that admits only `/app/ws` (ws_auth::browser_app_token). */
export function browserSocketURL(launch: URL): URL {
  const endpoint = new URL("/app/ws", launch.origin);
  endpoint.protocol = launch.protocol === "https:" ? "wss:" : "ws:";
  return endpoint;
}

export function installBrowserHost(): void {
  const launch = new URL(location.href);
  if (!isBrowserPane(launch)) return;

  const fragment = new URLSearchParams(launch.hash.slice(1));
  const listener = fragment.get("token");
  let token = listener;
  try {
    if (listener) sessionStorage.setItem("cmux.browser.appLink", listener);
    else token = sessionStorage.getItem("cmux.browser.appLink");
  } catch {
    // A tab with storage disabled still has its launch token until it closes.
  }
  if (fragment.has("token")) {
    fragment.delete("token");
    launch.hash = fragment.toString();
    history.replaceState(history.state, "", launch);
  }
  const endpoint = browserSocketURL(launch);
  document.documentElement.dataset.cmuxBrowserPane = "";
  document.title = "cmux NEXT";
  followBrowserTheme();
  setNativeHost(async (method, params) => {
    switch (method) {
      case "ready":
      case "handshake": {
        // l10n-allow: the browser host's connect error, a developer/URL-context message surfaced in the dev console
        if (!window.isSecureContext) throw new Error("Open cmux over HTTPS or on localhost to connect this browser.");
        // l10n-allow: the browser host's connect error, a developer/URL-context message surfaced in the dev console
        if (!token) throw new Error("Open the browser link from your cmux daemon to connect this tab.");
        const sessionId = new URL(location.href).searchParams.get("session") ?? undefined;
        return {
          protocolVersion: 1,
          transport: "acpmux-websocket",
          browserDevice: true,
          endpoint: endpoint.href,
          token,
          sessionId,
          sessionMustExist: Boolean(sessionId),
        };
      }
      case "chat.persistSession":
      case "session.persist": {
        if (typeof params.sessionId !== "string" || !params.sessionId) return;
        const url = new URL(location.href);
        url.searchParams.set("session", params.sessionId);
        history.replaceState(history.state, "", url);
        return;
      }
      case "cmux.page.heartbeat":
        return { rest: true };
      default:
        // l10n-allow: the browser host's connect error, a developer/URL-context message surfaced in the dev console
        throw new Error(`This browser does not support ${method}.`);
    }
  });
  // Back, Forward and in-page chat links select through the pane's own chat.select. The first
  // route rides the handshake's sessionId, so a route read before the pane mounts is not replayed.
  installBrowserNavigation(selectBrowserRoute);
}

function selectBrowserRoute(route: BrowserChatRoute | undefined): void {
  const select = window.cmuxAcpmuxActions?.["chat.select"];
  if (route && select) void Promise.resolve(select({ sessionId: route.session })).catch(() => undefined);
}
