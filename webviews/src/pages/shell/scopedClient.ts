// The client one shell page gets (`ctx.client`). It wraps the shell's one bridge client and
// tracks every subscription, pending call and host-call handler the page made, so `page.reset`
// can end all of them: after `close()` each pending call rejects with `cmux.protocol.closed`, each
// subscription is unsubscribed and gets no more events, and each handler is removed. A late reply
// of an old call is ignored.
import {
  pageError,
  type PageCallOptions,
  type PageClient,
  type PageEventMeta,
  type PageHandler,
} from "../shared/pageClient";

export class ScopedPageClient implements PageClient {
  private closed = false;
  private readonly pending = new Set<(error: Error) => void>();
  private readonly unsubscribes = new Set<() => void>();
  private readonly unhandles = new Set<() => void>();

  constructor(private readonly inner: PageClient) {}

  get isClosed(): boolean {
    return this.closed;
  }

  /** Open calls and subscriptions (tests and the debug state read it). */
  get openCount(): { calls: number; subscriptions: number } {
    return { calls: this.pending.size, subscriptions: this.unsubscribes.size };
  }

  call<R>(op: string, params: unknown, options?: PageCallOptions): Promise<R> {
    if (this.closed) return Promise.reject(closedError());
    return new Promise<R>((resolve, reject) => {
      const fail = (error: Error) => reject(error);
      this.pending.add(fail);
      this.inner.call<R>(op, params, options).then(
        (value) => {
          if (!this.pending.delete(fail)) return;
          resolve(value);
        },
        (error: unknown) => {
          if (!this.pending.delete(fail)) return;
          reject(error);
        },
      );
    });
  }

  async subscribe<E>(
    stream: string,
    onEvent: (data: E, seq: number, meta?: PageEventMeta) => void,
    filter?: Record<string, unknown>,
  ): Promise<() => void> {
    if (this.closed) throw closedError();
    // A subscribe in flight when the page resets: the stream is closed as soon as it opens.
    const inner = await this.inner.subscribe<E>(
      stream,
      (data, seq, meta) => {
        if (!this.closed) onEvent(data, seq, meta);
      },
      filter,
    );
    if (this.closed) {
      inner();
      throw closedError();
    }
    let active = true;
    const unsubscribe = () => {
      if (!active) return;
      active = false;
      this.unsubscribes.delete(unsubscribe);
      inner();
    };
    this.unsubscribes.add(unsubscribe);
    return unsubscribe;
  }

  handle(op: string, handler: PageHandler): () => void {
    if (this.closed) return () => undefined;
    const remove = this.inner.handle(op, handler);
    const unhandle = () => {
      if (!this.unhandles.delete(unhandle)) return;
      remove();
    };
    this.unhandles.add(unhandle);
    return unhandle;
  }

  /** Ends everything the page opened. Idempotent. */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    const error = closedError();
    for (const fail of this.pending) fail(error);
    this.pending.clear();
    for (const unsubscribe of this.unsubscribes) unsubscribe();
    for (const unhandle of this.unhandles) unhandle();
  }
}

function closedError(): Error {
  return pageError("cmux.protocol.closed", "the page was reset", true);
}
