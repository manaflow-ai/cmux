/**
 * Subclassing `Error` in TypeScript:
 * https://stackoverflow.com/a/41102306/376773
 */
interface LambdaErrorPayload {
    errorMessage?: string;
    errorType?: string;
    stackTrace?: string | string[];
}
export declare class LambdaError extends Error {
    constructor(data?: LambdaErrorPayload);
}
export {};
