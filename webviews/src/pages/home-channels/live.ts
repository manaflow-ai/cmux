// A Chief's live run text (`chief-live-v1`, the "Live frames" contract both brains send): while a
// run works, its reply's and thought's text streams in `step.delta` frames and a compact "working
// on" line in `run.activity`. The page keeps the text so far per running run (view state only;
// no owner stores it), shows the reply's text in the run card and the typing row, and the line
// under the typing row. Live text is keyed by conversation, author and run (a Cloud brain counts
// `run_<n>` per Chief). A missed frame (a `seq` gap) asks the owner for its `run.live` snapshot,
// which replaces the conversation's live text (so does a `run.live` the owner sends when a step
// starts again); a step's row after its last frame, the run's end or its posted reply drops it.
import { useCallback, useSyncExternalStore } from "react";
import type { HomeLiveFrame, HomeLiveSnapshot, HomeMessage } from "./types";

export interface LiveStep {
  step: string;
  kind: "talk" | "thought";
  /** The last frame applied. */
  seq: number;
  text: string;
  /** The step's last frame came (`final`). */
  ended: boolean;
}

export interface LiveRun {
  conversation: string;
  author: string;
  run: string;
  steps: readonly LiveStep[];
  activity?: { line: string; since: number; at: number };
}

/** The most of one step's text the page keeps (UTF-16 units; the owner's buffer keeps 64 KiB). */
const MAX_STEP_UNITS = 64 * 1024;
/** Runs whose reply posted or that ended, and steps whose row came: their late frames are dropped. */
const ENDED_LIMIT = 512;

const key = (conversation: string, author: string, run: string) => `${conversation}\0${author}\0${run}`;

/** `talk:3` -> 3 (the reply segment); other steps after every segment. */
const segment = (step: string) => {
  const match = /^talk:(\d+)$/.exec(step);
  return match ? Number(match[1]) : Number.MAX_SAFE_INTEGER;
};

/** The reply so far: the run's talk steps in order, joined by a blank line (as a draft). */
export function liveReply(live: LiveRun | undefined): string {
  if (!live) return "";
  return live.steps
    .filter((step) => step.kind === "talk" && step.text.trim())
    .sort((a, b) => segment(a.step) - segment(b.step))
    .map((step) => step.text.trim())
    .join("\n\n");
}

/** `text` from UTF-16 index `from`, never starting inside a surrogate pair. */
function from(text: string, start: number): string {
  const code = text.charCodeAt(start);
  return text.slice(code >= 0xdc00 && code <= 0xdfff ? start + 1 : start);
}

/** The end of `text` that fits a line or two: "…" and its last `max` characters. */
export function tail(text: string, max: number): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length <= max ? flat : `…${from(flat, flat.length - max + 1).trimStart()}`;
}

export class LiveBook {
  private readonly runs = new Map<string, LiveRun>();
  /** Keys of runs (`conversation\0author\0run`) and steps (`…\0step`) that ended. */
  private readonly ended: string[] = [];
  private readonly listeners = new Set<() => void>();
  private version = 0;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;

  get(conversation: string, author: string, run: string): LiveRun | undefined {
    return this.runs.get(key(conversation, author, run));
  }

  /** The conversation's live runs, in the order they began streaming. */
  inConversation(conversation: string): LiveRun[] {
    return [...this.runs.values()].filter((live) => live.conversation === conversation);
  }

  /** Applies frames in order (each with its author); answers the conversations that missed one
   * (ask for a snapshot). */
  apply(frames: readonly HomeLiveFrame[]): Set<string> {
    const gaps = new Set<string>();
    let changed = false;
    for (const frame of frames) {
      if (frame.type === "run.live") {
        this.snapshot(frame, false);
        gaps.delete(frame.conversation);
        changed = true;
        continue;
      }
      if (!frame.author) continue;
      const id = key(frame.conversation, frame.author, frame.run);
      if (this.ended.includes(id)) continue;
      const held = this.runs.get(id) ?? {
        conversation: frame.conversation,
        author: frame.author,
        run: frame.run,
        steps: [],
      };
      if (frame.type === "run.activity") {
        if (held.activity && held.activity.at > frame.at) continue;
        this.runs.set(id, { ...held, activity: { line: frame.line, since: frame.since, at: frame.at } });
        changed = true;
        continue;
      }
      if (this.ended.includes(`${id}\0${frame.step}`)) continue;
      const index = held.steps.findIndex((step) => step.step === frame.step);
      const step = index >= 0 ? held.steps[index]! : undefined;
      // `seq` 0 on a streaming step starts it again (the owner also sends its run.live).
      const restart = step !== undefined && frame.seq === 0 && !step.ended;
      if (step && !restart && frame.seq <= step.seq) continue;
      if (!restart && ((!step && frame.seq !== 0) || (step && (step.ended || frame.seq !== step.seq + 1)))) {
        gaps.add(frame.conversation);
        continue;
      }
      let text = (restart ? "" : (step?.text ?? "")) + frame.text;
      if (text.length > MAX_STEP_UNITS) text = from(text, text.length - MAX_STEP_UNITS);
      const next: LiveStep = { step: frame.step, kind: frame.kind, seq: frame.seq, text, ended: frame.final === true };
      const steps = [...held.steps];
      if (index >= 0) steps[index] = next;
      else steps.push(next);
      this.runs.set(id, { ...held, steps });
      changed = true;
    }
    if (changed) this.bump();
    return gaps;
  }

  /** The owner's `run.live`: the conversation's live text is replaced by it. */
  snapshot(snapshot: HomeLiveSnapshot, notify = true): void {
    for (const [id, live] of this.runs) if (live.conversation === snapshot.conversation) this.runs.delete(id);
    for (const run of snapshot.runs) {
      if (!run.author) continue;
      const id = key(snapshot.conversation, run.author, run.run);
      if (this.ended.includes(id)) continue;
      this.runs.set(id, {
        conversation: snapshot.conversation,
        author: run.author,
        run: run.run,
        steps: run.steps
          .filter((step) => !this.ended.includes(`${id}\0${step.step}`))
          .map(({ final, ...step }) => ({ ...step, ended: final === true })),
        activity: run.activity,
      });
    }
    if (notify) this.bump();
  }

  /** A run ended (its status left `running`): its live text goes and later frames are dropped. */
  end(conversation: string, author: string, run: string): void {
    const id = key(conversation, author, run);
    this.remember(id);
    if (this.runs.delete(id)) this.bump();
  }

  /** Rows of these talk and thought steps came: a step whose last frame came leaves (its row
   * has the whole text), and a late frame of it is dropped. */
  rowsWritten(conversation: string, author: string, run: string, steps: readonly string[]): void {
    const id = key(conversation, author, run);
    const held = this.runs.get(id);
    if (!held) return;
    const done = new Set(held.steps.filter((step) => step.ended && steps.includes(step.step)).map((s) => s.step));
    if (done.size === 0) return;
    for (const step of done) this.remember(`${id}\0${step}`);
    this.runs.set(id, { ...held, steps: held.steps.filter((step) => !done.has(step.step)) });
    this.bump();
  }

  /** A reply posted: the run whose turn it ends (same author) leaves its live place. */
  posted(message: HomeMessage, runOf: (message: HomeMessage) => string | undefined): void {
    const run = runOf(message);
    if (run) this.end(message.conversation, message.author, run);
  }

  /** Offline: every live text goes (the owner sends the snapshot again on the next join). */
  clear(): void {
    if (this.runs.size === 0) return;
    this.runs.clear();
    this.bump();
  }

  private remember(id: string): void {
    if (this.ended.includes(id)) return;
    this.ended.push(id);
    if (this.ended.length > ENDED_LIMIT) this.ended.splice(0, this.ended.length - ENDED_LIMIT);
  }

  private bump(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }
}

/** One run's live text: re-renders when that run's live state changes. */
export function useLiveRun(
  book: LiveBook | undefined,
  conversation: string,
  author: string,
  run: string,
): LiveRun | undefined {
  const subscribe = useCallback((listener: () => void) => (book ? book.subscribe(listener) : () => {}), [book]);
  return useSyncExternalStore(subscribe, () => book?.get(conversation, author, run));
}

/** The live runs of a conversation (the typing row): the same array while nothing changed. */
export function useLiveInConversation(
  book: LiveBook | undefined,
  conversation: string | undefined,
): readonly LiveRun[] {
  const subscribe = useCallback((listener: () => void) => (book ? book.subscribe(listener) : () => {}), [book]);
  const version = useSyncExternalStore(subscribe, () => book?.getVersion() ?? 0);
  return cached(book, conversation, version);
}

const NONE: readonly LiveRun[] = [];
const lists = new WeakMap<LiveBook, { conversation?: string; version: number; runs: readonly LiveRun[] }>();

function cached(book: LiveBook | undefined, conversation: string | undefined, version: number): readonly LiveRun[] {
  if (!book || !conversation) return NONE;
  const held = lists.get(book);
  if (held && held.conversation === conversation && held.version === version) return held.runs;
  const runs = book.inConversation(conversation);
  const next = runs.length === 0 ? NONE : runs;
  lists.set(book, { conversation, version, runs: next });
  return next;
}
