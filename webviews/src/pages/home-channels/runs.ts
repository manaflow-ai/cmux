// The page's agent runs (`conversation-runs-v1`): the trajectory of each Chief turn, from either
// owner (the local daemon, a Cloud owner through it), kept as view state. A run shows on the reply
// whose `clientMessageId` is its `turn` (same author); a running run with no reply yet shows as live
// work under the message it answers. Rows read one run each through `useRun` (an external store with
// per-run versions), so a streaming run re-renders only its own card.
import { useCallback, useSyncExternalStore } from "react";
import { stepMessage } from "./runMessages";
import type { HomeMessage, HomeRun, HomeRunChange, HomeRunStep } from "./types";

export interface RunEntry {
  run: HomeRun;
  /** The steps known so far, by seq. */
  steps: readonly HomeRunStep[];
  /** Every step was read from the owner (not only the ones events brought). */
  complete: boolean;
  /** Cached when steps arrive; timeline lookups never scan a run per render. */
  hasMessages?: boolean;
}

const MAX_RUNS = 400;
const MAX_REPLIED = 20_000;
/** A running run with no write for this long stopped answering (its agent crashed or lost the
 * owner): it shows as stalled and no longer makes its Chief look working. */
export const STALE_RUN_MS = 30 * 60_000;

export const isStale = (run: HomeRun, now: number): boolean =>
  run.status === "running" && run.updatedAt > 0 && now - run.updatedAt > STALE_RUN_MS;

/** Whether `next` is at least as new as `held`. Owners with revisions say so exactly; a Cloud
 * brain's run has none (rev 0): then an ended run never goes back to running, and a longer run
 * (more steps) wins. */
function newerRun(next: HomeRun, held: HomeRun): boolean {
  if (next.rev || held.rev) return next.rev >= held.rev;
  if (held.status !== "running" && next.status === "running") return false;
  return next.stepCount >= held.stepCount;
}

/** The same for one step: without revisions an ended step never goes back to running. */
function newerStep(next: HomeRunStep, held: HomeRunStep): boolean {
  if (next.rev || held.rev) return next.rev >= held.rev;
  return !(held.status !== "running" && held.status !== undefined && next.status === "running");
}

const turnKey = (run: HomeRun) => (run.turn ? `${run.conversation}\0${run.turn}\0${run.author}` : undefined);

export class RunBook {
  private readonly runs = new Map<string, RunEntry>();
  /** `conversation\0turn\0author` to run key. */
  private readonly byTurn = new Map<string, string>();
  /** Reply keys (`conversation\0turn\0author`) of the agent messages the page has seen. */
  private readonly replied = new Set<string>();
  /** Message ids in the timeline/thread cache. Anchored runs stay available while these are held. */
  private loadedMessages = new Set<string>();
  private loadedReplies = new Set<string>();
  /** `conversation\0message` to the keys of the runs that work on that message. */
  private readonly byAnswer = new Map<string, Set<string>>();
  /** The one answer row currently chosen for each run (a report must not render twice). */
  private readonly runAnswers = new Map<string, string | undefined>();
  private readonly listeners = new Set<() => void>();
  private version = 0;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;

  /** A run's key: its id is unique per author only (a Cloud brain counts `run_<n>` per Chief). */
  private key(conversation: string, author: string, id: string): string {
    return `${conversation}\0${author}\0${id}`;
  }

  get(conversation: string, author: string, id: string): RunEntry | undefined {
    return this.runs.get(this.key(conversation, author, id));
  }

  /** The run that ends with this reply (an agent's message whose key is the run's turn). */
  forReply(message: HomeMessage): RunEntry | undefined {
    if (!message.clientMessageId) return undefined;
    const key = this.byTurn.get(`${message.conversation}\0${message.clientMessageId}\0${message.author}`);
    return key ? this.runs.get(key) : undefined;
  }

  /** Runs that work on this message and whose reply the page has not seen: live work, or a run
   * that failed or stopped with no reply (shown where it was asked). A finished run whose reply
   * went into a thread the page has not loaded stays out (it shows on its reply). Transcript
   * includes silent summaries too, so their steps can be loaded when they enter the viewport. */
  liveFor(message: HomeMessage, includeSilent = false): RunEntry[] {
    const keys = this.byAnswer.get(`${message.conversation}\0${message.id}`);
    if (!keys) return [];
    const out: RunEntry[] = [];
    for (const key of keys) {
      const entry = this.runs.get(key);
      if (!entry) continue;
      const reply = turnKey(entry.run);
      const replied = reply !== undefined && this.replied.has(reply);
      // A silent Chief turn can still contain messages: keep them beside its question.
      const messages = entry.hasMessages ?? false;
      if (entry.run.status === "running" || ((includeSilent || entry.run.status !== "done" || messages) && !replied))
        out.push(entry);
    }
    return out.sort((a, b) => a.run.startedAt - b.run.startedAt);
  }

  /** Messages the page loaded or was sent: a run whose reply arrived leaves its live place. */
  noteMessages(messages: readonly HomeMessage[]): void {
    let changed = false;
    for (const message of messages) {
      if (!message.clientMessageId) continue;
      const key = `${message.conversation}\0${message.clientMessageId}\0${message.author}`;
      if (this.replied.has(key)) continue;
      // The oldest keys go first (a Set keeps insertion order).
      if (this.replied.size >= MAX_REPLIED) this.replied.delete(this.replied.values().next().value!);
      this.replied.add(key);
      changed = changed || this.byTurn.has(key);
    }
    if (changed) this.bump();
  }

  /** Replace the actual retained timeline and thread window, never the ever-seen history. */
  setLoadedMessages(messages: readonly HomeMessage[]): void {
    this.loadedMessages = new Set(messages.map((message) => `${message.conversation}\0${message.id}`));
    this.loadedReplies = new Set(
      messages
        .filter((message) => message.clientMessageId)
        .map((message) => `${message.conversation}\0${message.clientMessageId}\0${message.author}`),
    );
    let changed = false;
    for (const [key, entry] of this.runs) changed = this.indexAnswer(key, entry.run) || changed;
    changed = this.evict() || changed;
    if (changed) this.bump();
  }

  /** The turn keys of the agent messages in `messages` (to read their runs). */
  static turns(messages: readonly HomeMessage[], agents: ReadonlySet<string>): string[] {
    const keys = new Set<string>();
    for (const message of messages)
      if (message.clientMessageId && agents.has(message.author)) keys.add(message.clientMessageId);
    return [...keys].slice(-200);
  }

  /** Runs of a conversation still working (a Chief's live state); a stalled run is not. */
  running(conversation: string, now = Date.now()): HomeRun[] {
    return [...this.runs.values()]
      .filter((entry) => entry.run.conversation === conversation && entry.run.status === "running")
      .filter((entry) => !isStale(entry.run, now))
      .map((entry) => entry.run);
  }

  /** Runs that can project the conversation's current goal strip. */
  goalEntries(conversation: string): RunEntry[] {
    return [...this.runs.values()]
      .filter((entry) => entry.run.conversation === conversation)
      .filter((entry) => entry.run.status === "running" || entry.run.status === "failed")
      .sort((a, b) => b.run.updatedAt - a.run.updatedAt);
  }

  goalEntry(conversation: string): RunEntry | undefined {
    return this.goalEntries(conversation)[0];
  }

  /** Summaries the owner listed: kept steps stay; a newer summary replaces an older one. */
  setRuns(runs: readonly HomeRun[]): void {
    let changed = false;
    // Some Cloud owners expose neither revision nor update time. Only a fresh summary lookup
    // invalidates those cached steps; live events and repeated card loads do not trigger retries.
    for (const run of runs) changed = this.put(run, [], false, run.rev === 0 && run.updatedAt === 0) || changed;
    if (changed) this.bump();
  }

  /** Steps the owner read for a run (`complete` once every page is in). */
  setSteps(run: HomeRun, steps: readonly HomeRunStep[], complete: boolean): void {
    if (this.put(run, steps, complete)) this.bump();
  }

  /** One owner event per changed run. */
  apply(changes: readonly HomeRunChange[]): void {
    let changed = false;
    for (const change of changes) changed = this.put(change.run, change.steps, false) || changed;
    if (changed) this.bump();
  }

  private put(run: HomeRun, steps: readonly HomeRunStep[], complete: boolean, invalidateComplete = false): boolean {
    const key = this.key(run.conversation, run.author, run.id);
    const current = this.runs.get(key);
    const newer = !current || newerRun(run, current.run);
    if (!newer && steps.length === 0 && !(complete && current && !current.complete)) return false;
    const merged = new Map((current?.steps ?? []).map((step) => [step.id, step]));
    for (const step of steps) {
      const held = merged.get(step.id);
      if (!held || newerStep(step, held)) merged.set(step.id, step);
    }
    const latest = newer ? run : current!.run;
    // A summary can advance an existing step without changing the step count. Only a full read
    // of this revision can make it complete again; Cloud summaries without rev use updatedAt.
    const unchanged =
      !invalidateComplete &&
      current !== undefined &&
      latest.rev === current.run.rev &&
      latest.updatedAt === current.run.updatedAt;
    const entry: RunEntry = {
      run: latest,
      steps: [...merged.values()].sort((a, b) => a.seq - b.seq),
      complete: (((current?.complete ?? false) && unchanged) || (complete && newer)) && merged.size >= latest.stepCount,
      hasMessages: (current?.hasMessages ?? false) || steps.some((step) => stepMessage(step) !== undefined),
    };
    this.runs.set(key, entry);
    if (entry.run.turn) this.byTurn.set(`${entry.run.conversation}\0${entry.run.turn}\0${entry.run.author}`, key);
    this.indexAnswer(key, entry.run);
    if (this.runs.size > MAX_RUNS) this.evict();
    return true;
  }

  /** One loaded question anchors the run even when the first answer is outside the window. */
  private indexAnswer(key: string, run: HomeRun): boolean {
    const asked = run.answers.find((id) => this.loadedMessages.has(`${run.conversation}\0${id}`)) ?? run.answers[0];
    const answer = asked ? `${run.conversation}\0${asked}` : undefined;
    const previous = this.runAnswers.get(key);
    if (previous === answer) return false;
    if (previous) {
      const keys = this.byAnswer.get(previous);
      keys?.delete(key);
      if (!keys?.size) this.byAnswer.delete(previous);
    }
    this.runAnswers.set(key, answer);
    if (answer) {
      const keys = this.byAnswer.get(answer) ?? new Set<string>();
      keys.add(key);
      this.byAnswer.set(answer, keys);
    }
    return true;
  }

  /** Keep loaded questions/replies; bound the finished records without a retained transcript row. */
  private evict(): boolean {
    const unshown = [...this.runs.entries()]
      .filter(([, { run }]) => run.status !== "running")
      .filter(([, { run }]) => !run.answers.some((id) => this.loadedMessages.has(`${run.conversation}\0${id}`)))
      .filter(([, { run }]) => !this.loadedReplies.has(turnKey(run) ?? ""))
      .sort((a, b) => a[1].run.updatedAt - b[1].run.updatedAt);
    const removed = unshown.slice(0, Math.max(0, unshown.length - MAX_RUNS));
    for (const [key, entry] of removed) {
      this.runs.delete(key);
      const reply = turnKey(entry.run);
      if (reply && this.byTurn.get(reply) === key) this.byTurn.delete(reply);
      const answer = this.runAnswers.get(key);
      if (answer) {
        const keys = this.byAnswer.get(answer);
        keys?.delete(key);
        if (!keys?.size) this.byAnswer.delete(answer);
      }
      this.runAnswers.delete(key);
    }
    return removed.length > 0;
  }

  clear(): void {
    this.runs.clear();
    this.byTurn.clear();
    this.replied.clear();
    this.byAnswer.clear();
    this.runAnswers.clear();
    this.loadedMessages.clear();
    this.loadedReplies.clear();
    this.bump();
  }

  private bump(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }
}

/** A row's run (its reply's run, or one run by id): re-renders only when that entry changes. */
export function useRunEntry(book: RunBook | undefined, select: (book: RunBook) => RunEntry | undefined) {
  const subscribe = useCallback((listener: () => void) => (book ? book.subscribe(listener) : () => {}), [book]);
  return useSyncExternalStore(subscribe, () => (book ? select(book) : undefined));
}

/** The live runs under a message (stable while nothing changed: compared by entry identity). */
export function useLiveRuns(
  book: RunBook | undefined,
  message: HomeMessage,
  includeSilent = false,
): readonly RunEntry[] {
  const subscribe = useCallback((listener: () => void) => (book ? book.subscribe(listener) : () => {}), [book]);
  const id = `${message.conversation}\0${message.id}\0${includeSilent}`;
  return useSyncExternalStore(subscribe, () =>
    liveKey(book, id, () => (book ? book.liveFor(message, includeSilent) : NONE)),
  );
}

const NONE: readonly RunEntry[] = [];
const liveCache = new WeakMap<RunBook, Map<string, readonly RunEntry[]>>();

/** The same array while the entries are the same (useSyncExternalStore needs a stable snapshot);
 * one cached array per message, dropped when the message has no live run. */
function liveKey(book: RunBook | undefined, message: string, read: () => readonly RunEntry[]): readonly RunEntry[] {
  if (!book) return NONE;
  let byMessage = liveCache.get(book);
  if (!byMessage) liveCache.set(book, (byMessage = new Map()));
  const next = read();
  if (next.length === 0) {
    byMessage.delete(message);
    return NONE;
  }
  const held = byMessage.get(message);
  if (held && held.length === next.length && held.every((entry, index) => entry === next[index])) return held;
  byMessage.set(message, next);
  return next;
}

/** A link a step may open: http(s) or a cmux scheme (an owner that skipped the check sends no
 * other through). */
export function safeLink(url: string): boolean {
  return /^(https?|cmux(-[a-z0-9-]+)?):\/\/\S+$/.test(url);
}

/** "$0.04": a run's cost at pay-per-token API prices (the harness's estimate), when the owner knows it. */
export function runCost(usd: number | undefined): string | undefined {
  if (usd === undefined) return undefined;
  return usd < 0.01 ? `$${usd.toFixed(3)}` : `$${usd.toFixed(2)}`;
}

/** "48k tokens": a run's tokens in and out. */
export function runTokens(run: HomeRun): string | undefined {
  const usage = run.usage;
  if (!usage) return undefined;
  const total = (usage.input ?? 0) + (usage.output ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0);
  if (total === 0) return undefined;
  return total >= 1000 ? `${Math.round(total / 1000)}k` : String(total);
}
