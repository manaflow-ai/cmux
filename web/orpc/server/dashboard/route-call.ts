import type { DashboardContext } from "./base";
import { refusalFromResponse } from "./errors";

type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

type RouteHandler<Params> =
  | ((request: Request) => Promise<Response>)
  | ((request: Request, context: { params: Promise<Params> }) => Promise<Response>);

export type RouteCall<Params> = {
  readonly method: Method;
  /** The route's public path, e.g. `/api/coderouter/accounts/abc/sharing`. */
  readonly path: string;
  readonly params?: Params;
  readonly search?: Readonly<Record<string, string | null | undefined>>;
  readonly headers?: Readonly<Record<string, string>>;
  readonly body?: unknown;
};

/** Headers that describe the RPC transport, not the caller. */
const TRANSPORT_HEADERS = new Set(["content-length", "content-type", "accept", "accept-encoding", "transfer-encoding"]);

/**
 * Run an existing API route handler in process for a dashboard procedure.
 *
 * The coderouter, subrouter, VM access-grant, and Vault routes keep their
 * authentication, origin checks, rate limits, telemetry, and error envelopes
 * inside the handler. Calling the handler with the caller's own headers keeps
 * exactly that behavior for the dashboard and for native clients, with one
 * implementation. The procedure's `.output()` schema validates what the
 * handler returns, and error envelopes become typed refusals.
 */
export async function callRoute<Params>(
  context: DashboardContext,
  handler: RouteHandler<Params>,
  call: RouteCall<Params>,
): Promise<unknown> {
  const url = new URL(call.path, context.request.url);
  for (const [key, value] of Object.entries(call.search ?? {})) {
    if (value !== null && value !== undefined) url.searchParams.set(key, value);
  }
  const headers = new Headers();
  context.request.headers.forEach((value, key) => {
    if (!TRANSPORT_HEADERS.has(key.toLowerCase())) headers.set(key, value);
  });
  headers.set("accept", "application/json");
  for (const [key, value] of Object.entries(call.headers ?? {})) headers.set(key, value);
  if (call.body !== undefined) headers.set("content-type", "application/json");
  const request = new Request(url, {
    method: call.method,
    headers,
    body: call.body === undefined ? undefined : JSON.stringify(call.body),
    signal: context.request.signal,
  });
  const response = await (handler as (request: Request, context: { params: Promise<Params> }) => Promise<Response>)(
    request,
    { params: Promise.resolve(call.params ?? ({} as Params)) },
  );
  if (!response.ok) throw await refusalFromResponse(response);
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}
