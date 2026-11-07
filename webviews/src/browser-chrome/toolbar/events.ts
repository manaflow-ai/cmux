// The host's numbered one-shot requests (`ToolbarHostState.events`): each `seq` is handled once,
// in order, however many states repeat it before the page's ack reaches the host.

/** `binding`: the host's tab binding when it queued the event (`ToolbarHostState.events`). */
export type Numbered<T> = { seq: number; binding?: number; event: T };

/** The events after `lastSeq`, oldest first, and the newest seq once they are handled. */
export function freshEvents<T>(
  events: readonly Numbered<T>[],
  lastSeq: number,
): { fresh: Numbered<T>[]; lastSeq: number } {
  const fresh = events.filter((entry) => entry.seq > lastSeq).sort((a, b) => a.seq - b.seq);
  return { fresh, lastSeq: fresh.length > 0 ? fresh[fresh.length - 1].seq : lastSeq };
}
