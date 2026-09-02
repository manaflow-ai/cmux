const LOCAL_WEBSOCKET_URL = "ws://127.0.0.1:7681";
const LOCAL_MAC_WEBSOCKET_URL = "ws://127.0.0.1:7683/cmux";
const MAC_LAST_URL_KEY = "cmux-mac.web.lastWebSocketUrl";
const TUI_LAST_URL_KEY = "cmux-tui.web.lastWebSocketUrl";

interface LocationInput {
  hostname: string;
  port?: string;
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

export function defaultMacWebSocketUrl(hostname: string, pagePort = ""): string {
  if (isLocalHostname(hostname)) return LOCAL_MAC_WEBSOCKET_URL;
  const normalizedPort = pagePort && pagePort !== "443" ? `:${pagePort}` : "";
  return `wss://${hostname}${normalizedPort}/cmux`;
}

export function initialConnectionConfig(
  location: LocationInput,
  storage?: Pick<StorageInput, "getItem">,
  runtime: "tui" | "mac" = "tui",
): InitialConnectionConfig {
  const params = new URLSearchParams(location.search);
  const fragment = new URLSearchParams(location.hash.replace(/^#/, ""));
  const queryUrl = params.get("ws")?.trim();
  let rememberedUrl: string | null = null;
  try {
    const key = runtime === "mac" ? MAC_LAST_URL_KEY : TUI_LAST_URL_KEY;
    rememberedUrl = storage?.getItem(key)?.trim() || null;
  } catch {
    // Storage may be unavailable in privacy modes. The location default remains usable.
  }
  return {
    url: queryUrl || rememberedUrl || (
      runtime === "mac"
        ? defaultMacWebSocketUrl(location.hostname, location.port)
        : defaultWebSocketUrl(location.hostname)
    ),
    token: fragment.get("token")?.trim() || "",
  };
}

export function rememberWebSocketUrl(
  url: string,
  storage?: Pick<StorageInput, "setItem">,
  runtime: "tui" | "mac" = "tui",
): void {
  try {
    storage?.setItem(runtime === "mac" ? MAC_LAST_URL_KEY : TUI_LAST_URL_KEY, url);
  } catch {
    // Connecting should not fail just because localStorage is unavailable.
  }
}
