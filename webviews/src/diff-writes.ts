// The diff viewer's writes to its host (viewed marks, viewer preferences) as intents
// (plans/cmux-next/zero-latency.md). The viewer already applies each change to its own state in
// the input's frame; this outbox owns what happens after: one write in flight per file (or per
// preference key), in input order, a newer value replacing one still queued (a quick
// viewed-unviewed-viewed sends two writes, never a stale third), an operation id on every write
// (decision 31) and a record of refusals. Before, each change was a fire-and-forget call, so two
// quick toggles raced each other to the host.
import { callDiffComments } from "./comments/bridge";
import { IntentStore, defineIntent, type IntentSender } from "./protocol/intents";

/** One `cmuxDiffComments` method call. */
export interface DiffWrite {
  method: string;
  params: Record<string, unknown>;
}

const sender: IntentSender = {
  call: (_op, wire, options) => {
    const write = wire as DiffWrite;
    return callDiffComments<unknown>(write.method, write.params, { opid: options?.opid });
  },
};

const kinds = {
  /** The viewed state of one file in one scope: the latest value wins. */
  viewed: defineIntent<null, { resource: string; write: DiffWrite }>({
    op: "cmux.diff.comments",
    resource: (params) => params.resource,
    apply: (state) => state,
    wire: (params) => params.write,
    supersede: true,
  }),
  /** One set of viewer preference keys: the latest value wins. */
  prefs: defineIntent<null, { resource: string; write: DiffWrite }>({
    op: "cmux.diff.comments",
    resource: (params) => params.resource,
    apply: (state) => state,
    wire: (params) => params.write,
    supersede: true,
  }),
};

let store: IntentStore<null, typeof kinds> | null = null;

/** The outbox (one per page). */
export function diffWrites(): IntentStore<null, typeof kinds> {
  store ??= new IntentStore<null, typeof kinds>({
    initial: null,
    kinds,
    sender,
    opidPrefix: `diff-${Math.random().toString(36).slice(2, 8)}`,
    onTrace: (entry) => {
      if (entry.type === "err" && entry.kind === "viewed") {
        console.warn("cmux diff viewed state save failed", entry.detail);
      }
    },
  });
  return store;
}

/** Test hook: forgets the outbox (pending writes are dropped). */
export function resetDiffWritesForTesting(): void {
  store?.dispose();
  store = null;
}
