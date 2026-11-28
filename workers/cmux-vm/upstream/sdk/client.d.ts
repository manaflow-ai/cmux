export declare const DEFAULT_BASE_URL = "https://api.freestyle.sh";
/**
 * The version every API route carries. Exported for callers using the
 * {@link Freestyle.fetch} escape hatch, who have to name it themselves.
 *
 * This is **not** a prefix the client applies: every path in this SDK is
 * written out in full, `/v5/vms` and `/v5/identities`, matching the path the
 * API declares. A version quietly joined on the way out is a version nobody
 * can grep for.
 */
export declare const API_VERSION_PREFIX = "/v5";
/** Options every credential mode shares. */
interface TransportOptions {
    baseUrl?: string;
    /**
     * Transport to use instead of the built-in one, which speaks HTTP/2 on Node
     * and defers to the runtime's `fetch` everywhere else. Pass one to route
     * through a proxy, size the connection pool yourself, or add retries.
     */
    fetch?: typeof fetch;
}
export type FreestyleOptions = ({
    apiKey?: string;
    identityAccessToken?: never;
} & TransportOptions) | ({
    identityAccessToken: string;
    apiKey?: never;
} & TransportOptions) | ({
    /** Stack access token used by the CLI; resolved to `teamId` at the gateway. */
    stackAccessToken: string;
    teamId: string;
    apiKey?: never;
    identityAccessToken?: never;
} & TransportOptions);
/** `undefined`/`null` query values are dropped; everything else is stringified. */
export type QueryValue = string | number | boolean | undefined | null;
/** Percent-encode one path segment (a VM/snapshot/VPC id or slug). */
export declare function segment(value: string): string;
/**
 * Thin HTTP client for the Freestyle public API: attaches the configured
 * credential, resolves the base URL, and turns non-2xx responses into
 * {@link FreestyleApiError}.
 *
 * Every request runs as a background request: the API detaches the work from
 * the HTTP connection, so a call that outlives the connection (a long
 * snapshot materialization, a cold VM boot — including one triggered by a
 * read that wakes the VM, a client/proxy timeout) still runs to completion.
 * Calls that finish within a few seconds return inline exactly as usual;
 * longer ones answer `202 Accepted` and the client transparently polls
 * `GET /v5/background-requests/{id}` until the result — same value, same
 * errors — is ready. If a finished result was too large to store (the API
 * caps stored bodies), idempotent GETs are re-fetched once directly: by then
 * the slow part (e.g. waking the VM) has already happened. Identity-token
 * clients are the one exception: their scope cannot reach the poll route,
 * so none of their requests are backgrounded.
 */
export declare class FreestyleClient {
    readonly baseUrl: string;
    private readonly authenticationHeaders;
    private readonly fetchImpl;
    /** Identity-token callers cannot poll `/v5/background-requests`, so their requests are never backgrounded. */
    private readonly backgroundEligible;
    constructor(options?: FreestyleOptions);
    /** Headers this client authenticates every request with, e.g. for a raw WebSocket handshake. */
    authHeaders(): Record<string, string>;
    /** Absolute URL for an API path, e.g. `/v5/vms/{id}` → `https://.../v5/vms/{id}`. */
    url(path: string, query?: Record<string, QueryValue>): string;
    /**
     * Low-level escape hatch: an authenticated `fetch` against the API, relative
     * to `baseUrl`. Pass the whole path, `/v5` included — the same paths the
     * methods above use, and the same ones the API declares. It is also how the
     * client follows a server-supplied URL (a 202's `resultUrl`), and the only
     * way to reach the unversioned `/status` and `/openapi.json`.
     */
    fetch(path: string, init?: RequestInit): Promise<Response>;
    /** A path or URL as this client's `fetch` resolves it: absolute URLs are
     * followed as given, everything else hangs off `baseUrl` with no version
     * segment added — the caller already supplied whatever version it wants. */
    private absoluteUrl;
    private request;
    /**
     * Follow a 202 from a backgrounded request: poll its result URL until the
     * stored response — success or error, identical to what the inline call
     * would have produced — is ready.
     */
    private pollBackgroundRequest;
    /** Turn a terminal API response into the call's value, or throw its error. */
    private finalize;
    get<T>(path: string, query?: Record<string, QueryValue>): Promise<T>;
    post<T>(path: string, body?: unknown): Promise<T>;
    patch<T>(path: string, body?: unknown): Promise<T>;
    put<T>(path: string, body?: unknown): Promise<T>;
    putEmpty<T>(path: string): Promise<T>;
    /** PUT raw bytes as `application/octet-stream`: a whole file, or one chunk of one. */
    putBytes<T>(path: string, rawBody: Uint8Array | Blob, query?: Record<string, QueryValue>, signal?: AbortSignal): Promise<T>;
    /**
     * GET a response whose body is bytes rather than JSON, returned unread so the
     * caller can stream it. Errors still surface as {@link FreestyleApiError}.
     */
    getBytes(path: string, query?: Record<string, QueryValue>, init?: {
        range?: string;
        signal?: AbortSignal;
    }): Promise<Response>;
    delete<T = void>(path: string, query?: Record<string, QueryValue>): Promise<T>;
}
export {};
//# sourceMappingURL=client.d.ts.map