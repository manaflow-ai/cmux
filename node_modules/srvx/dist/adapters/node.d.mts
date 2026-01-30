import { FetchHandler, NodeHttpHandler, NodeServerRequest, NodeServerResponse, Server, ServerOptions, ServerRequest } from "../_chunks/types-BtByT9ny.mjs";
import { FastURL$2 as FastURL } from "../_chunks/_url-D8u5OAto.mjs";
import NodeHttp from "node:http";
import { Readable } from "node:stream";

//#region src/adapters/_node/request.d.ts
type NodeRequestContext = {
  req: NodeServerRequest;
  res?: NodeServerResponse;
};
declare const NodeRequest: {
  new (nodeCtx: NodeRequestContext): ServerRequest;
};
//#endregion
//#region src/adapters/_node/headers.d.ts
type NodeRequestHeaders = InstanceType<typeof NodeRequestHeaders>;
declare const NodeRequestHeaders: {
  new (nodeCtx: {
    req: NodeServerRequest;
    res?: NodeServerResponse;
  }): globalThis.Headers;
};
declare const NodeResponseHeaders: {
  new (nodeCtx: {
    req?: NodeServerRequest;
    res: NodeServerResponse;
  }): globalThis.Headers;
};
//#endregion
//#region src/adapters/_node/response.d.ts
// prettier-ignore
type PreparedNodeResponseBody = string | Buffer | Uint8Array | DataView | ReadableStream | Readable | undefined | null;
interface PreparedNodeResponse {
  status: number;
  statusText: string;
  headers: NodeHttp.OutgoingHttpHeader[];
  body: PreparedNodeResponseBody;
}
/**
* Fast Response for Node.js runtime
*
* It is faster because in most cases it doesn't create a full Response instance.
*/
declare const NodeResponse: {
  new (body?: BodyInit | null, init?: ResponseInit): globalThis.Response & {
    readonly nodeResponse: () => PreparedNodeResponse;
  };
};
type NodeResponse = InstanceType<typeof NodeResponse>;
//#endregion
//#region src/adapters/_node/send.d.ts
declare function sendNodeResponse(nodeRes: NodeServerResponse, webRes: Response | NodeResponse): Promise<void>;
//#endregion
//#region src/adapters/node.d.ts
declare function serve(options: ServerOptions): Server;
declare function toNodeHandler(fetchHandler: FetchHandler): NodeHttpHandler;
//#endregion
export { NodeResponse as FastResponse, FastURL, NodeRequest, NodeRequestHeaders, NodeResponse, NodeResponseHeaders, sendNodeResponse, serve, toNodeHandler };