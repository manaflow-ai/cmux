import { Server, ServerOptions } from "../_chunks/types-BtByT9ny.mjs";
import * as CF from "@cloudflare/workers-types";

//#region src/adapters/cloudflare.d.ts
declare const FastURL: typeof globalThis.URL;
declare const FastResponse: typeof globalThis.Response;
declare function serve(options: ServerOptions): Server<CF.ExportedHandlerFetchHandler>;
//#endregion
export { FastResponse, FastURL, serve };