// The diff viewer's writes to its host (viewed marks, viewer preferences) as intents
// (plans/cmux-next/zero-latency.md). The viewer already applies each change to its own state in
// the input's frame; this outbox owns what happens after: one write in flight per file (or per
// preference key), in input order, a newer value replacing one still queued (a quick
// viewed-unviewed-viewed sends two writes, never a stale third), an operation id on every write
// (decision 31) and a record of refusals. Before, each change was a fire-and-forget call, so two
// quick toggles raced each other to the host.
//
// One outbox per mounted viewer, never per document: in the R94 page shell a claim does not reload
// the page, so page.reset unmounts the viewer (disposing its outbox: pending writes, refusals and
// trace) and the next claim mounts a new one.
import { useEffect, useState } from "react";
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

/**
 * The outbox's intent kinds. The diff page is Swift-routed (cmuxPage bridge to the PageRouter),
 * which does not echo opids on events yet, so every kind confirms on `ok` (zero-latency.md,
 * "Swift-routed pages").
 */
export const DIFF_WRITE_KINDS = {
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

export type DiffWrites = IntentStore<null, typeof DIFF_WRITE_KINDS>;

/** A new outbox. Owners dispose it when their viewer unmounts (`useDiffWrites` does). */
export function createDiffWrites(): DiffWrites {
  return new IntentStore<null, typeof DIFF_WRITE_KINDS>({
    initial: null,
    kinds: DIFF_WRITE_KINDS,
    sender,
    opidPrefix: `diff-${Math.random().toString(36).slice(2, 8)}`,
    onTrace: (entry) => {
      if (entry.type === "err" && entry.kind === "viewed") {
        console.warn("cmux diff viewed state save failed", entry.detail);
      }
    },
  });
}

/**
 * The mounted viewer's outbox: created with the component, disposed when it unmounts (the page
 * shell's reset), so nothing pending or refused outlives the page it came from. The effect is
 * only the unmount cleanup; test/diff-writes-shell.test.tsx covers it.
 */
export function useDiffWrites(): DiffWrites {
  const [writes] = useState(createDiffWrites);
  useEffect(() => () => writes.dispose(), [writes]);
  return writes;
}
