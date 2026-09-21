/**
 * Work a route may run once its response has left (usage-event rows,
 * metadata backfills): the route supplies `runAfterResponse`, so the writes
 * still happen but the client does not wait for them. Workflows given no
 * sink run the work inline, as they always did.
 */
export type VmDeferSink = (work: () => Promise<void>) => void;

/**
 * A sink whose units run in the order they were handed in, each after the
 * previous one settles, so deferred ledger rows keep their lifecycle order
 * (`vm.create.requested` before `vm.created`) whatever the scheduler does
 * with the callbacks it is given (Next's `after()` queue is concurrent; the
 * detached fallback starts everything at once). A unit still starts only
 * when the scheduler invokes it, and a failed unit never blocks the next.
 */
export function orderedDeferSink(schedule: VmDeferSink): VmDeferSink {
  let tail: Promise<void> = Promise.resolve();
  return (work) => {
    const previous = tail;
    let start: () => void = () => undefined;
    const started = new Promise<void>((resolve) => {
      start = resolve;
    });
    const run = started.then(() => previous).then(work);
    tail = run.catch(() => undefined);
    schedule(() => {
      start();
      return run;
    });
  };
}
