// A stand-in host for a page store: answers ops with `answer`, delivers events with `emit`, and
// counts each op's calls and reply bytes (the JSON the relay would carry). The History and Feed
// delta-read detectors and bench/page-delta-reads.bench.ts read the same counts on base and head.
import type { PageClient } from "../../src/pages/shared/pageClient";

export interface OpCount {
  calls: number;
  bytes: number;
  params: unknown[];
}

export class CountingPageClient implements PageClient {
  readonly ops = new Map<string, OpCount>();
  private readonly streams = new Map<string, Set<(data: unknown, seq: number) => void>>();
  private seq = 0;

  constructor(private readonly answer: (op: string, params: unknown) => unknown) {}

  count(op: string): OpCount {
    let count = this.ops.get(op);
    if (!count) {
      count = { calls: 0, bytes: 0, params: [] };
      this.ops.set(op, count);
    }
    return count;
  }

  reset(): void {
    this.ops.clear();
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    const text = JSON.stringify(this.answer(op, params) ?? null);
    const count = this.count(op);
    count.calls += 1;
    count.bytes += text.length;
    count.params.push(params);
    // The page decodes what the relay carried: a fresh copy, as over the wire.
    return JSON.parse(text) as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    let listeners = this.streams.get(stream);
    if (!listeners) {
      listeners = new Set();
      this.streams.set(stream, listeners);
    }
    const listener = onEvent as (data: unknown, seq: number) => void;
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  handle(): () => void {
    return () => undefined;
  }

  emit(stream: string, data: unknown): void {
    this.seq += 1;
    for (const listener of this.streams.get(stream) ?? []) listener(data, this.seq);
  }
}

/** Lets queued promise work (a store's read and its reply) run. */
export const settle = async (rounds = 5): Promise<void> => {
  for (let round = 0; round < rounds; round += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};
