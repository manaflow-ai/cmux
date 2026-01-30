/// <reference types="node" />
import http, { Server } from 'node:http';
import { Deferred } from './deferred';
import { Lambda, InvokeParams, InvokeResult } from './types';
export declare class RuntimeServer extends Server {
    version: string;
    initDeferred: Deferred<InvokeResult | void>;
    resultDeferred: Deferred<InvokeResult>;
    private nextDeferred;
    private invokeDeferred;
    private lambda;
    private currentRequestId;
    constructor(fn: Lambda);
    resetInvocationState(): void;
    serve(req: http.IncomingMessage, res: http.ServerResponse): Promise<any>;
    handleNextInvocation(req: http.IncomingMessage, res: http.ServerResponse): Promise<void>;
    handleInvocationResponse(req: any, res: any, requestId: string): Promise<void>;
    handleInvocationError(req: any, res: any, requestId: string): Promise<void>;
    handleInitializationError(req: any, res: any): Promise<void>;
    invoke(params?: InvokeParams): Promise<InvokeResult>;
    close(callback?: (err?: Error) => void): this;
}
