import type * as EdgePrimitives from '@edge-runtime/primitives';
import type { DispatchFetch } from './types';
import { VM, type VMContext, type VMOptions } from './vm';
export interface EdgeVMOptions<T extends EdgeContext> {
    /**
     * Provide code generation options to the Node.js VM.
     * If you don't provide any option, code generation will be disabled.
     */
    codeGeneration?: VMOptions<T>['codeGeneration'];
    /**
     * Allows to extend the VMContext. Note that it must return a contextified
     * object so ideally it should return the same reference it receives.
     */
    extend?: (context: EdgeContext) => EdgeContext & T;
    /**
     * Code to be evaluated as when the Edge Runtime is created. This is handy
     * to run code directly instead of first creating the runtime and then
     * evaluating.
     */
    initialCode?: string;
}
export declare class EdgeVM<T extends EdgeContext = EdgeContext> extends VM<T> {
    readonly dispatchFetch: DispatchFetch;
    constructor(options?: EdgeVMOptions<T>);
}
export type EdgeContext = VMContext & {
    self: EdgeContext;
    globalThis: EdgeContext;
    AbortController: typeof EdgePrimitives.AbortController;
    AbortSignal: typeof EdgePrimitives.AbortSignal;
    atob: typeof EdgePrimitives.atob;
    Blob: typeof EdgePrimitives.Blob;
    btoa: typeof EdgePrimitives.btoa;
    console: typeof EdgePrimitives.console;
    crypto: typeof EdgePrimitives.crypto;
    Crypto: typeof EdgePrimitives.Crypto;
    CryptoKey: typeof EdgePrimitives.CryptoKey;
    DOMException: typeof EdgePrimitives.DOMException;
    Event: typeof EdgePrimitives.Event;
    EventTarget: typeof EdgePrimitives.EventTarget;
    fetch: typeof EdgePrimitives.fetch;
    FetchEvent: typeof EdgePrimitives.FetchEvent;
    File: typeof EdgePrimitives.File;
    FormData: typeof EdgePrimitives.FormData;
    Headers: typeof EdgePrimitives.Headers;
    PromiseRejectionEvent: typeof EdgePrimitives.PromiseRejectionEvent;
    ReadableStream: typeof EdgePrimitives.ReadableStream;
    ReadableStreamBYOBReader: typeof EdgePrimitives.ReadableStreamBYOBReader;
    ReadableStreamDefaultReader: typeof EdgePrimitives.ReadableStreamDefaultReader;
    Request: typeof EdgePrimitives.Request;
    Response: typeof EdgePrimitives.Response;
    setTimeout: typeof EdgePrimitives.setTimeout;
    setInterval: typeof EdgePrimitives.setInterval;
    structuredClone: typeof EdgePrimitives.structuredClone;
    SubtleCrypto: typeof EdgePrimitives.SubtleCrypto;
    TextDecoder: typeof EdgePrimitives.TextDecoder;
    TextDecoderStream: typeof EdgePrimitives.TextDecoderStream;
    TextEncoder: typeof EdgePrimitives.TextEncoder;
    TextEncoderStream: typeof EdgePrimitives.TextEncoderStream;
    TransformStream: typeof EdgePrimitives.TransformStream;
    URL: typeof EdgePrimitives.URL;
    URLPattern: typeof EdgePrimitives.URLPattern;
    URLSearchParams: typeof EdgePrimitives.URLSearchParams;
    WritableStream: typeof EdgePrimitives.WritableStream;
    WritableStreamDefaultWriter: typeof EdgePrimitives.WritableStreamDefaultWriter;
    EdgeRuntime: string;
};
