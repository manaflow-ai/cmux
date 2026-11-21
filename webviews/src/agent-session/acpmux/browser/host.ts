// The listener serves the same pane as the app. It supplies the listener token in the
// fragment so it never reaches the HTTP server. Only this origin can receive either proof.
import { followBrowserTheme } from "../../guest/theme";
import { setNativeHost } from "../native";

export function isBrowserPane(url: URL): boolean {
  return (
    (url.protocol === "https:" || url.protocol === "http:") &&
    (url.pathname === "/app/" || url.pathname === "/app/index.html")
  );
}

export function installBrowserHost(): void {
  const launch = new URL(location.href);
  if (!isBrowserPane(launch)) return;

  const fragment = new URLSearchParams(launch.hash.slice(1));
  const listener = fragment.get("token");
  let token = listener;
  try {
    if (listener) sessionStorage.setItem("cmux.browser.listener", listener);
    else token = sessionStorage.getItem("cmux.browser.listener");
  } catch {
    // A tab with storage disabled still has its launch token until it closes.
  }
  if (fragment.has("token")) {
    fragment.delete("token");
    launch.hash = fragment.toString();
    history.replaceState(history.state, "", launch);
  }
  const endpoint = new URL("/", launch.origin);
  endpoint.protocol = launch.protocol === "https:" ? "wss:" : "ws:";
  document.documentElement.dataset.cmuxBrowserPane = "";
  document.title = "cmux NEXT";
  followBrowserTheme();
  setNativeHost(async (method, params) => {
    switch (method) {
      case "ready":
      case "handshake": {
        if (!window.isSecureContext) throw new Error("Open cmux over HTTPS or on localhost to connect this browser.");
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
        throw new Error(`This browser does not support ${method}.`);
    }
  });
}
