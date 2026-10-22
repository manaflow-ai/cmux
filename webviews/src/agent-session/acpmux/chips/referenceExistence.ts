// Which repositories have pull request #N, for a bare `#N` the transcript names no repository for
// (conversation/bareReferences.ts, rule c), from the App's pull request cache, never one GitHub
// call per chip: the candidates' addresses go to the host in one `link.inspect`, which reads them
// in one batched GraphQL call (AgentReplyPullRequests.register), then `pr.inspect` answers each
// from that cache. An answer is kept for the page's life. While the host says a read is running,
// `pr.inspect` is asked again every WAIT_MS (a call to the App), at most MAX_TRIES times;
// resetReferenceExistence clears those timers.
import { useEffect, useSyncExternalStore } from "react";
import { callChipHost } from "./host";

type State = "yes" | "no" | "asking";

const MAX_BATCH = 64;
const WAIT_MS = 1_500;
const MAX_TRIES = 20;
const MAX_KEPT = 2_000;

const known = new Map<string, State>();
const timers = new Set<ReturnType<typeof setTimeout>>();
const listeners = new Set<() => void>();
let queued: string[] = [];
let scheduled = false;

function changed() {
  for (const listener of listeners) listener();
}

function record(url: string, state: State) {
  if (!known.has(url)) return; // reset meanwhile
  known.set(url, state);
  changed();
}

function settle(url: string, tries: number) {
  void callChipHost("pr.inspect", { url }).then((reply) => {
    const value = reply as { pullRequest?: { number?: unknown } | null; reading?: unknown } | undefined;
    if (value?.pullRequest && typeof value.pullRequest.number === "number") return record(url, "yes");
    if (value?.reading === true && tries < MAX_TRIES && known.has(url)) {
      const timer = setTimeout(() => {
        timers.delete(timer);
        settle(url, tries + 1);
      }, WAIT_MS);
      timers.add(timer);
      return;
    }
    // No pull request (an issue, another repository's number), no gh, or a read that failed:
    // the number is not this repository's, as far as the App knows.
    record(url, "no");
  });
}

function flush() {
  scheduled = false;
  while (queued.length) {
    const batch = queued.splice(0, MAX_BATCH);
    // The host registers the batch before it answers, so each `pr.inspect` after it shares the
    // batch's one read instead of starting its own.
    void callChipHost("link.inspect", { paths: [], urls: batch }).then(() => {
      for (const url of batch) settle(url, 0);
    });
  }
}

function ask(urls: readonly string[]) {
  if (known.size > MAX_KEPT) resetReferenceExistence();
  for (const url of urls) {
    if (known.has(url)) continue;
    known.set(url, "asking");
    queued.push(url);
  }
  if (queued.length && !scheduled) {
    scheduled = true;
    queueMicrotask(flush);
  }
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/** Whether each of `urls` is a pull request the App's cache knows; undefined until all answer.
 *  An empty list asks nothing. */
export function usePullRequestsExist(urls: readonly string[]): readonly boolean[] | undefined {
  const key = urls.join(" ");
  useEffect(() => {
    if (key) ask(key.split(" "));
  }, [key]);
  // The snapshot is a string, so an unchanged answer is the same value and re-renders nothing.
  const read = () =>
    key
      ? key
          .split(" ")
          .map((url) => known.get(url) ?? "asking")
          .join(" ")
      : "";
  const states = useSyncExternalStore(subscribe, read, read);
  if (!states) return undefined;
  const each = states.split(" ");
  return each.includes("asking") ? undefined : each.map((state) => state === "yes");
}

/** Tests and the gallery start from nothing. */
export function resetReferenceExistence(): void {
  for (const timer of timers) clearTimeout(timer);
  timers.clear();
  known.clear();
  queued = [];
  changed();
}
