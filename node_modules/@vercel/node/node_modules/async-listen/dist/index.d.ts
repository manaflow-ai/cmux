/// <reference types="node" />
/// <reference types="node" />
import * as net from 'net';
import { EventEmitter } from 'events';
import type { OverloadedParameters } from './overloaded-parameters';
export interface ServerLike extends EventEmitter {
    listen: (...args: any[]) => any;
    address: net.Server['address'];
    protocol?: string;
}
export declare function listen<Server extends ServerLike>(server: Server, ...args: OverloadedParameters<Server['listen']>): Promise<URL>;
export default listen;
