import { DenoFetchHandler, Server, ServerOptions } from "../_chunks/types-BtByT9ny.mjs";
import { FastURL$2 as FastURL } from "../_chunks/_url-D8u5OAto.mjs";

//#region src/adapters/deno.d.ts
declare const FastResponse: typeof globalThis.Response;
declare function serve(options: ServerOptions): DenoServer;
// https://docs.deno.com/api/deno/~/Deno.serve
declare class DenoServer implements Server<DenoFetchHandler> {
  #private;
  readonly runtime = "deno";
  readonly options: Server["options"];
  readonly deno: Server["deno"];
  readonly serveOptions: Deno.ServeTcpOptions | (Deno.ServeTcpOptions & Deno.TlsCertifiedKeyPem);
  readonly fetch: DenoFetchHandler;
  constructor(options: ServerOptions);
  serve(): Promise<this>;
  get url(): string | undefined;
  ready(): Promise<Server>;
  close(): Promise<void>;
}
//#endregion
export { FastResponse, FastURL, serve };