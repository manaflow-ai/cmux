/// <reference types="node" />

import { RequestListener, IncomingMessage, ServerResponse } from 'http'

export type RequestHandler = (req: IncomingMessage, res: ServerResponse) => any
declare function serve(fn: RequestHandler): RequestListener

export function run(req: IncomingMessage, res: ServerResponse, fn: RequestHandler): Promise<void>
export function json(req: IncomingMessage, info?: { limit?: string | number, encoding?: string }): Promise<any>
export function text(req: IncomingMessage, info?: { limit?: string | number, encoding?: string }): Promise<string>
export function buffer(req: IncomingMessage, info?: { limit?: string | number, encoding?: string }): Promise<Buffer | string>
export function send(res: ServerResponse, code: number, data?: any): Promise<void>
export function createError(code: number, msg: string, orig?: Error): Error & { statusCode: number, originalError?: Error }
export function sendError(req: IncomingMessage, res: ServerResponse, info: { statusCode?: number, status?: number, message?: string, stack?: string }): Promise<void>
export default serve
