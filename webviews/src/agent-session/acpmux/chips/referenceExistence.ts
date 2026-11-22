// Which repositories have pull request #N, for a bare `#N` the transcript names no repository for
// (conversation/bareReferences.ts, rule c), from the App's pull request cache, never one GitHub
// call per chip. Addresses go in batches of at most MAX_BATCH, at most MAX_RUNNING batches at a
// time (well under the host's 200 kept links). Each round of a batch first registers the
// addresses still unanswered with one `link.inspect`, which reads the stale ones in one batched
// GraphQL call (AgentReplyPullRequests.register) and marks them as being read, then asks
// `pr.inspect` for each, which answers from that cache and starts no read of its own. While the
// host is still reading, the next round waits WAIT_MS, doubling to MAX_WAIT_MS, up to ROUNDS
// rounds (about two minutes); an address still being read then stays unknown (the chip shows rule
// d's repository) and is asked again when a chip for it mounts. An answer is kept for the page's
// life (the oldest past MAX_KEPT go, and a shown chip asks again); resetReferenceExistence clears
// the timers.
import { useEffect, useSyncExternalStore } from "react";
import { callChipHost } from "./host";
import { useTranscriptReadOnly } from "../conversation/readOnly";

type State = "yes" | "no" | "asking" | "unknown";

const MAX_BATCH = 64;
const MAX_RUNNING = 2;
const WAIT_MS = 1_500;
const MAX_WAIT_MS = 30_000;
const ROUNDS = 8;
const MAX_KEPT = 2_000;

const known = new Map<string, State>();
const timers = new Set<ReturnType<typeof setTimeout>>();
const listeners = new Set<() => void>();
let queued: string[] = [];
let running = 0;
/** Bumped by a reset: a batch from before it records nothing. */
let generation = 0;

function changed() {
  for (const listener of listeners) listener();
}

const wait = (ms: number) =>
  new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      timers.delete(timer);
      resolve();
    }, ms);
    timers.add(timer);
  });

async function run(batch: string[], started: number) {
  let pending = batch;
  for (let round = 0; pending.length && round < ROUNDS; round++) {
    if (round) await wait(Math.min(WAIT_MS * 2 ** (round - 1), MAX_WAIT_MS));
    if (started !== generation) return;
    await callChipHost("link.inspect", { paths: [], urls: pending });
    const replies = await Promise.all(pending.map((url) => callChipHost("pr.inspect", { url })));
    if (started !== generation) return;
    const reading: string[] = [];
    replies.forEach((reply, index) => {
      const value = reply as { pullRequest?: { number?: unknown } | null; reading?: unknown } | undefined;
      const url = pending[index]!;
      // No pull request (an issue, another repository's number), no gh, or a failed read: not
      // this repository's, as far as the App knows.
      if (value?.pullRequest && typeof value.pullRequest.number === "number") known.set(url, "yes");
      else if (value?.reading === true) reading.push(url);
      else known.set(url, "no");
    });
    pending = reading;
    changed();
  }
  for (const url of pending) known.set(url, "unknown");
  if (pending.length) changed();
}

let pumping = false;

function pump() {
  pumping = false;
  while (running < MAX_RUNNING && queued.length) {
    const started = generation;
    running += 1;
    void run(queued.splice(0, MAX_BATCH), started).finally(() => {
      if (started !== generation) return;
      running -= 1;
      pump();
    });
  }
}

/** Drops the oldest answers past MAX_KEPT; an address still being asked about stays. */
function trim() {
  for (const [url, state] of known) {
    if (known.size <= MAX_KEPT) break;
    if (state !== "asking") known.delete(url);
  }
}

function ask(urls: readonly string[]) {
  let added = false;
  for (const url of urls) {
    if (known.has(url) && known.get(url) !== "unknown") continue;
    known.set(url, "asking");
    queued.push(url);
    added = true;
  }
  if (!added) return;
  trim();
  // One microtask later, so every chip a render mounted asks in the same batch.
  if (pumping) return;
  pumping = true;
  queueMicrotask(pump);
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/** Whether each of `urls` is a pull request the App's cache knows; undefined until all answer.
 *  An empty list asks nothing. */
export function usePullRequestsExist(urls: readonly string[]): readonly boolean[] | undefined {
  // Read only (a guest), nothing is asked: every reference reads as not known.
  const readOnly = useTranscriptReadOnly();
  const key = readOnly ? "" : urls.join(" ");
  // The snapshot is a string, so an unchanged answer is the same value and re-renders nothing.
  const read = () =>
    key
      ? key
          .split(" ")
          .map((url) => known.get(url) ?? "missing")
          .join(" ")
      : "";
  const states = useSyncExternalStore(subscribe, read, read);
  // Asks for every address it has no answer for: on mount, and again after one was dropped.
  const missing = states.includes("missing");
  useEffect(() => {
    if (key) ask(key.split(" "));
  }, [key, missing]);
  if (!states) return undefined;
  const each = states.split(" ");
  return each.some((state) => state !== "yes" && state !== "no") ? undefined : each.map((state) => state === "yes");
}

/** Tests and the gallery start from nothing. */
export function resetReferenceExistence(): void {
  for (const timer of timers) clearTimeout(timer);
  timers.clear();
  known.clear();
  queued = [];
  running = 0;
  pumping = false;
  generation += 1;
  changed();
}
