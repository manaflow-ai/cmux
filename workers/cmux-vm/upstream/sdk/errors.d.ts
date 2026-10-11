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
//# sourceMappingURL=errors.d.ts.map