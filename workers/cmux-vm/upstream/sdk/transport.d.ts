type Http2Fetch = typeof fetch | null;
/** A `fetch` that multiplexes over a shared HTTP/2 connection, or `null` off Node. */
export declare function createHttp2Fetch(): Promise<Http2Fetch>;
/**
 * The transport used when the caller passed no `fetch`. Resolved on first
 * request, not at construction: Workers charges module scope against a 1s
 * startup budget and forbids I/O outside a request handler.
 *
 * Plain `http:` requests skip the dispatcher and take the runtime's own fetch.
 * They could never multiplex, and a capped pool would only serialise them,
 * which is the wrong trade for a local gateway or an h1 proxy.
 */
export declare function defaultFetch(): typeof fetch;
export {};
//# sourceMappingURL=transport.d.ts.map