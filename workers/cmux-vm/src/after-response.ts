/**
 * Work that must happen for a request but not before its answer: the audit
 * row of a mutation, written on the request's own database connection after
 * the response is handed back. The Worker passes `ExecutionContext.waitUntil`
 * so the runtime keeps the request alive until that work ends.
 */
import { Context } from "effect";

/** Keeps the Worker alive until `work` settles (`ExecutionContext.waitUntil`). */
export type Defer = (work: Promise<unknown>) => void;

/** Present only when the caller can keep the request alive past its answer; without it, deferred work runs inline. */
export class AfterResponse extends Context.Tag("cmux-vm/AfterResponse")<AfterResponse, Defer>() {}

/** A request handler that may be given a way to keep work alive after it answers. */
export type DeferringHandler = (request: Request, defer?: Defer) => Promise<Response>;
