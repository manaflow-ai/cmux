const LOCAL_WEBSOCKET_URL = "ws://127.0.0.1:7681";
const LAST_URL_KEY = "cmux-tui.web.lastWebSocketUrl";

interface LocationInput {
  hostname: string;
  search: string;
  hash: string;
  pathname?: string;
  protocol?: string;
  host?: string;
}

interface StorageInput {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface InitialConnectionConfig {
  url: string;
  token: string;
  /** The page came from the daemon's own listener (`/pages/<page>/`), so its
   * WebSocket is the same origin and a token in the fragment connects at once. */
  servedByDaemon: boolean;
}

function isLocalHostname(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1" || hostname === "[::1]";
}

export function defaultWebSocketUrl(hostname: string): string {
  return isLocalHostname(hostname) ? LOCAL_WEBSOCKET_URL : `wss://${hostname}:8443`;
}

/** The daemon's listener serves page files at `/pages/<page>/` and accepts
 * the WebSocket upgrade on any path of the same origin (spec/transports.md,
 * "App listener and page files"). */
export function daemonServedWebSocketUrl(location: LocationInput): string | null {
  if (!location.pathname?.startsWith("/pages/") || !location.host) return null;
  return `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/`;
}

export function initialConnectionConfig(
  location: LocationInput,
  storage?: Pick<StorageInput, "getItem">,
): InitialConnectionConfig {
  const params = new URLSearchParams(location.search);
  const fragment = new URLSearchParams(location.hash.replace(/^#/, ""));
  const queryUrl = params.get("ws")?.trim();
  let rememberedUrl: string | null = null;
  try {
    rememberedUrl = storage?.getItem(LAST_URL_KEY)?.trim() || null;
  } catch {
    // Storage may be unavailable in privacy modes. The location default remains usable.
  }
  const daemonUrl = daemonServedWebSocketUrl(location);
  return {
    url: queryUrl || daemonUrl || rememberedUrl || defaultWebSocketUrl(location.hostname),
    token: fragment.get("token")?.trim() || "",
    servedByDaemon: daemonUrl !== null && !queryUrl,
  };
}

export function rememberWebSocketUrl(url: string, storage?: Pick<StorageInput, "setItem">): void {
  try {
    storage?.setItem(LAST_URL_KEY, url);
  } catch {
    // Connecting should not fail just because localStorage is unavailable.
  }
}
