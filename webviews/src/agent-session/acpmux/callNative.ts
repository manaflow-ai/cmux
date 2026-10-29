// A page action: the connected client's (chat actions run against acpmux), else the native host.
// Moved out of App.tsx (audit P10) so the transcript row modules (rows/) call the host the same way.
import { postNative } from "./native";

export function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  return postNative<T>(method, params);
}
