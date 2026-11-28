// Typed edges over the untyped acpmux transport. The method maps come from the daemon's
// registry through generated/methods.ts; an untyped method's params and result are `unknown`.

import type {
  AcpmuxNotificationName,
  AcpmuxNotifications,
  AcpmuxRequestName,
  AcpmuxRequests,
} from "./generated/methods";

export type RawRequest = (method: string, params: Record<string, unknown>, deadline?: number) => Promise<unknown>;

/** Sends `method` through `request` with params and result typed by the registry. Does not validate the reply. */
export function typedRequest<M extends AcpmuxRequestName>(
  request: RawRequest,
  method: M,
  params: AcpmuxRequests[M]["params"],
  deadline?: number,
): Promise<AcpmuxRequests[M]["result"]> {
  return request(method, params as Record<string, unknown>, deadline) as Promise<AcpmuxRequests[M]["result"]>;
}

/** Narrows a notification by method name. Matches the name only; params are trusted as the daemon sent them. */
export function isNotification<N extends AcpmuxNotificationName>(
  notification: { method: string; params?: unknown },
  name: N,
): notification is { method: N; params: AcpmuxNotifications[N] } {
  return notification.method === name;
}
