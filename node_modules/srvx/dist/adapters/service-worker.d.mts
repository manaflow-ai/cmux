import { Server, ServerOptions, ServerRequest } from "../_chunks/types-BtByT9ny.mjs";

//#region src/adapters/service-worker.d.ts
declare const FastURL: typeof globalThis.URL;
declare const FastResponse: typeof globalThis.Response;
type ServiceWorkerHandler = (request: ServerRequest, event: FetchEvent) => Response | Promise<Response>;
declare function serve(options: ServerOptions): Server<ServiceWorkerHandler>;
//#endregion
export { FastResponse, FastURL, ServiceWorkerHandler, serve };