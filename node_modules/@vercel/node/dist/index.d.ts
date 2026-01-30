import type { ServerResponse, IncomingMessage } from 'http';
import type { Headers } from 'undici';
import type { Readable } from 'stream';

export type VercelRequestCookies = { [key: string]: string };
export type VercelRequestQuery = { [key: string]: string | string[] };
export type VercelRequestBody = any;

export type VercelRequest = IncomingMessage & {
  query: VercelRequestQuery;
  cookies: VercelRequestCookies;
  body: VercelRequestBody;
};

export type VercelResponse = ServerResponse & {
  send: (body: any) => VercelResponse;
  json: (jsonBody: any) => VercelResponse;
  status: (statusCode: number) => VercelResponse;
  redirect: (statusOrUrl: string | number, url?: string) => VercelResponse;
};

export type VercelApiHandler = (
  req: VercelRequest,
  res: VercelResponse
) => void | Promise<void>;

/** @deprecated Use VercelRequestCookies instead. */
export type NowRequestCookies = VercelRequestCookies;

/** @deprecated Use VercelRequestQuery instead. */
export type NowRequestQuery = VercelRequestQuery;

/** @deprecated Use VercelRequestBody instead. */
export type NowRequestBody = any;

/** @deprecated Use VercelRequest instead. */
export type NowRequest = VercelRequest;

/** @deprecated Use VercelResponse instead. */
export type NowResponse = VercelResponse;

/** @deprecated Use VercelApiHandler instead. */
export type NowApiHandler = VercelApiHandler;

export interface VercelProxyResponse {
  status: number;
  headers: Headers;
  body: Readable | Buffer | null;
  encoding: BufferEncoding;
}
