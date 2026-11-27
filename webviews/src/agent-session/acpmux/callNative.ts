import { postNative } from "./native";
import { pageClientLink, whenPageClientBack } from "./sendWhenReady";

/// The page's own actions a send makes, which wait for the page's next client while it is away
/// (sendWhenReady.ts `pageClientLink`) instead of going to the app, which has none of them.
const WAITS_FOR_CLIENT = new Set(["chat.send"]);

export function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  if (WAITS_FOR_CLIENT.has(method) && pageClientLink.away())
    return whenPageClientBack(() => callNative<T>(method, params));
  return postNative<T>(method, params);
}
