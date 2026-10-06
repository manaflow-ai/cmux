// The latency harness's stand-in for the app's cmuxPage bridge: an in-page host with a fixed reply
// delay (`?hostDelay=`, default 40 ms, a realistic local IPC plus provider round trip), so any
// await on an input path shows up as a failed frame. Installed before the page module loads.
import { RECEIVE_NAME } from "../../src/pages/shared/pageClient";

type Envelope = { t: string; id?: number; op?: string; params?: unknown; stream?: string; sub?: number; opid?: string };
export type HostOp = (params: any, call: { opid?: string }) => unknown | Promise<unknown>;

export class HostError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

export interface MockHost {
  emit(stream: string, data: unknown, opid?: string): void;
  /** Every call the page made, in order. */
  readonly calls: Array<{ op: string; params: unknown; opid?: string }>;
  delayMs: number;
}

export function hostDelay(): number {
  const value = Number(new URLSearchParams(location.search).get("hostDelay"));
  return Number.isFinite(value) && value >= 0 && new URLSearchParams(location.search).has("hostDelay") ? value : 40;
}

export function installMockHost(ops: Record<string, HostOp>, streamNames: readonly string[]): MockHost {
  const streams = new Map<string, number>();
  const seqs = new Map<number, number>();
  let nextSub = 1;
  const host: MockHost = {
    calls: [],
    delayMs: hostDelay(),
    emit(stream, data, opid) {
      const sub = streams.get(stream);
      if (sub === undefined) return;
      const seq = (seqs.get(sub) ?? 0) + 1;
      seqs.set(sub, seq);
      const receive = (globalThis as unknown as Record<string, (message: unknown) => void>)[RECEIVE_NAME];
      setTimeout(() => receive?.(opid ? { t: "ev", sub, seq, data, opid } : { t: "ev", sub, seq, data }), 0);
    },
  };
  const wait = () => new Promise((resolve) => setTimeout(resolve, host.delayMs));
  const postMessage = async (message: Envelope): Promise<unknown> => {
    await wait();
    if (message.t === "sub" && message.stream) {
      if (!streamNames.includes(message.stream)) {
        return {
          t: "err",
          id: message.id,
          code: "cmux.protocol.unknown_op",
          message: message.stream,
          retryable: false,
        };
      }
      const sub = nextSub++;
      streams.set(message.stream, sub);
      return { t: "ok", id: message.id, value: { sub } };
    }
    if (message.t !== "call" || !message.op) return null;
    host.calls.push({ op: message.op, params: message.params, opid: message.opid });
    const op = ops[message.op];
    if (!op)
      return { t: "err", id: message.id, code: "cmux.protocol.unknown_op", message: message.op, retryable: false };
    try {
      return { t: "ok", id: message.id, value: (await op(message.params ?? {}, { opid: message.opid })) ?? null };
    } catch (error) {
      const failure = error as HostError;
      return {
        t: "err",
        id: message.id,
        code: failure.code ?? "cmux.page.failed",
        message: failure.message,
        retryable: false,
        details: failure.details,
      };
    }
  };
  (window as unknown as { webkit: unknown }).webkit = { messageHandlers: { cmuxPage: { postMessage } } };
  (window as unknown as { __mockHost: MockHost }).__mockHost = host;
  return host;
}
