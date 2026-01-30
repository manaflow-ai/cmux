/// <reference types="node" />
export interface SpawnError extends NodeJS.ErrnoException {
    spawnargs: string[];
}
/**
 * A simple type guard for objects.
 *
 * @param obj - A possible object
 */
export declare const isObject: (obj: unknown) => obj is Record<string, unknown>;
/**
 * A type guard for `try...catch` errors.
 * @deprecated use `require('node:util').types.isNativeError(error)` instead
 */
export declare const isError: (error: unknown) => error is Error;
export declare const isErrnoException: (error: unknown) => error is NodeJS.ErrnoException;
interface ErrorLike {
    message: string;
    name?: string;
    stack?: string;
}
/**
 * A type guard for error-like objects.
 */
export declare const isErrorLike: (error: unknown) => error is ErrorLike;
/**
 * Parses errors to string, useful for getting the error message in a
 * `try...catch` statement.
 */
export declare const errorToString: (error: unknown, fallback?: string) => string;
/**
 * Normalizes unknown errors to the Error type, useful for working with errors
 * in a `try...catch` statement.
 */
export declare const normalizeError: (error: unknown) => Error;
export declare function isSpawnError(v: unknown): v is SpawnError;
export {};
