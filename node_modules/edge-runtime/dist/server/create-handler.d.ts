/// <reference types="node" />
import type { EdgeRuntime } from '../edge-runtime';
import type { IncomingMessage, ServerResponse } from 'http';
import type { Logger } from '../types';
import type { EdgeContext } from '@edge-runtime/vm';
export interface Options<T extends EdgeContext> {
    /**
     * A logger interface. If none is provided there will be no logs.
     */
    logger?: Logger;
    /**
     * The runtime where the FetchEvent will be triggered whenever the server
     * receives a request.
     */
    runtime: EdgeRuntime<T>;
}
/**
 * Creates an HHTP handler that can be used to create a Node.js HTTP server.
 * Whenever a request is handled it will transform it into a `dispatchFetch`
 * call for the given `EdgeRuntime`. Then it will transform the response
 * into an HTTP response.
 */
export declare function createHandler<T extends EdgeContext>(options: Options<T>): {
    handler: (req: IncomingMessage, res: ServerResponse) => Promise<void>;
    waitUntil: () => Promise<unknown[]>;
};
