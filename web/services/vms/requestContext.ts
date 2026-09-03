import { AsyncLocalStorage } from "node:async_hooks";

import type { VmErrorResponseInput } from "./routeHelpers";

/**
 * Client identity a cmux app or CLI attaches to every Cloud VM request. All
 * headers are optional; older nightlies send none of them and still work.
 */
export type VmClientIdentity = {
  readonly name?: string;
  readonly version?: string;
  readonly build?: string;
  readonly channel?: string;
  readonly userAgent?: string;
  /** Client-minted id for one logical request (echoed back, spans, PostHog). */
  readonly requestId?: string;
  /** Trace id the client minted before calling us (W3C `traceparent`). */
  readonly traceId?: string;
};

/**
 * One Cloud VM API request as seen by telemetry. Created by
 * `withAuthedVmApiRoute` before auth and enriched as the request proceeds;
 * read by the error choke point (`vmErrorResponse`) and the response
 * finalizer so a single error carries user, operation, client, trace ids and
 * the full scrubbed error input without threading them through every call.
 */
export type VmRequestContext = {
  readonly route: string;
  readonly method: string;
  readonly operation: string;
  readonly startedAtMs: number;
  readonly client: VmClientIdentity;
  /** Vercel's per-invocation request id (`x-vercel-id`), when present. */
  readonly vercelRequestId?: string;
  /** Server trace/span ids of the route span (Axiom lookup keys). */
  traceId?: string;
  spanId?: string;
  userId?: string;
  /** The last error input that flowed through `vmErrorResponse`. */
  lastError?: VmErrorResponseInput;
};

const storage = new AsyncLocalStorage<VmRequestContext>();

export function runWithVmRequestContext<T>(context: VmRequestContext, fn: () => T): T {
  return storage.run(context, fn);
}

export function currentVmRequestContext(): VmRequestContext | undefined {
  return storage.getStore();
}

const CLIENT_HEADER_MAX = 120;

export const VM_CLIENT_REQUEST_ID_HEADER = "x-cmux-client-request-id";

/** Read the client identity headers into a bounded, printable shape. */
export function vmClientIdentityFromRequest(request: Request): VmClientIdentity {
  const header = (name: string): string | undefined => {
    const raw = request.headers.get(name);
    if (!raw) return undefined;
    const trimmed = raw.trim();
    if (!trimmed) return undefined;
    // Drop control characters; header values reach span attributes and logs.
    const printable = trimmed.replace(/[^\x20-\x7e]/g, "");
    return printable.length > 0 ? printable.slice(0, CLIENT_HEADER_MAX) : undefined;
  };
  const requestIdRaw = header(VM_CLIENT_REQUEST_ID_HEADER);
  return {
    name: header("x-cmux-client"),
    version: header("x-cmux-app-version"),
    build: header("x-cmux-app-build"),
    channel: header("x-cmux-channel"),
    userAgent: header("user-agent"),
    requestId: requestIdRaw && /^[A-Za-z0-9._:-]{1,80}$/.test(requestIdRaw) ? requestIdRaw : undefined,
    traceId: traceIdFromTraceparent(request.headers.get("traceparent")),
  };
}

const TRACEPARENT = /^[0-9a-f]{2}-([0-9a-f]{32})-[0-9a-f]{16}-[0-9a-f]{2}$/i;

/** The trace id of a syntactically valid W3C traceparent, else undefined. */
export function traceIdFromTraceparent(value: string | null | undefined): string | undefined {
  if (!value) return undefined;
  const match = TRACEPARENT.exec(value.trim());
  if (!match) return undefined;
  const traceId = match[1].toLowerCase();
  if (/^0+$/.test(traceId)) return undefined;
  return traceId;
}
