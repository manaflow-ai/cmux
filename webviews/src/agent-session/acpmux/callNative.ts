import { postNative } from "./native";

export function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  return postNative<T>(method, params);
}
