/// <reference types="node" />
import { Options } from './create-handler';
import type { EdgeContext } from '@edge-runtime/vm';
import type { ListenOptions } from 'net';
interface ServerOptions<T extends EdgeContext> extends Options<T> {
}
export interface EdgeRuntimeServer {
    /**
     * The server URL.
     */
    url: string;
    /**
     * Waits for all the current effects and closes the server.
     */
    close: () => Promise<void>;
    /**
     * Waits for all current effects returning their result.
     */
    waitUntil: () => Promise<any[]>;
}
/**
 * This helper will create a handler based on the given options and then
 * immediately run a server on the provided port. If there is no port, the
 * server will use a random one.
 */
export declare function runServer<T extends EdgeContext>(options: ListenOptions & ServerOptions<T>): Promise<EdgeRuntimeServer>;
export {};
