/** Whether this is Node — the only runtime we reach for `undici` on. */
export declare function isNodeRuntime(): boolean;
/**
 * The runtime's own `fetch`, kept callable with the global as its receiver.
 * Not redundant: a detached reference makes workerd throw `Illegal invocation`,
 * and a wrapper survives a bundler hoisting it where `.bind()` may not.
 */
export declare const globalFetch: typeof fetch;
//# sourceMappingURL=runtime.d.ts.map