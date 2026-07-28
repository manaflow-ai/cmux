const LOCAL_WEBSOCKET_URL = "ws://127.0.0.1:7681";
const LAST_URL_KEY = "cmux-tui.web.lastWebSocketUrl";

interface LocationInput {
  hostname: string;
  search: string;
  hash: string;
}

interface StorageInput {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface InitialConnectionConfig {
  url: string;
  token: string;
}

function isLocalHostname(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1" || hostname === "[::1]";
}

export function defaultWebSocketUrl(hostname: string): string {
  return isLocalHostname(hostname) ? LOCAL_WEBSOCKET_URL : `wss://${hostname}:8443`;
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
  return {
    url: queryUrl || rememberedUrl || defaultWebSocketUrl(location.hostname),
    token: fragment.get("token")?.trim() || "",
  };
}

export function rememberWebSocketUrl(url: string, storage?: Pick<StorageInput, "setItem">): void {
  try {
    storage?.setItem(LAST_URL_KEY, url);
  } catch {
    // Connecting should not fail just because localStorage is unavailable.
  }
}
