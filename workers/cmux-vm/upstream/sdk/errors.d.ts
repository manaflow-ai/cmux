/**
 * The shape every failure on the Freestyle public API takes:
 * `{"code": "SCREAMING_SNAKE_CASE", "message": "human readable"}`.
 *
 * `code` is what you should branch on; `message` is prose and may be
 * reworded at any time.
 */
export interface FreestyleErrorBody {
    code: string;
    message: string;
}
/** Thrown for any non-2xx response from the Freestyle API. */
export declare class FreestyleApiError extends Error {
    /** A stable identifier for the failure, e.g. `"NOT_FOUND"`. */
    readonly code: string;
    /** The HTTP status code of the response. */
    readonly status: number;
    /** The request path that failed, for debugging. */
    readonly path?: string;
    constructor(status: number, body: FreestyleErrorBody, path?: string);
}
/** One underlying transport failure, copied explicitly so JSON logging retains it. */
export interface FreestyleConnectionError {
    name?: string;
    message?: string;
    code?: string;
    errno?: string | number;
    syscall?: string;
    address?: string;
    port?: number;
}
/** A failed fetch with underlying connection diagnostics; no HTTP response was received. */
export declare class FreestyleTransportError extends TypeError {
    readonly errors: FreestyleConnectionError[];
    constructor(cause: unknown, errors: FreestyleConnectionError[]);
    toJSON(): {
        name: string;
        message: string;
        errors: FreestyleConnectionError[];
    };
}
/** @internal Keep cancellations and unrelated custom-fetch errors unchanged. */
export declare function withConnectionDiagnostics(error: unknown): unknown;
//# sourceMappingURL=errors.d.ts.map