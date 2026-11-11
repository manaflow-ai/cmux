// `cmux app chat perf`: what a chat page draws while its records come in, measured in the
// person's own app (Release and Nightly too), through `window.cmuxAcpmuxBridge.perfCapture`.
// The app's `agent.chat.perf` control method calls it on one chat tab without focusing, showing
// or un-occluding anything (AgentChatPerfControl.swift).
//
// Nothing runs unless a capture does: the event path checks `chatPerfCapture.active` (one
// boolean), and the frame loop, the observers and the visibility listener exist only for the
// capture's window and are removed when it ends, also when it throws.
//
// Per record, arrival-to-paint is the time from when the selected chat's record reached the
// client (before it is applied) to the first frame painted after it: a frame callback posts a
// message, which runs as a task once that frame has rendered (test/support/paintedFrames.ts says
// why). A page that draws no frames (a hidden or fully covered page) has no such time, so the
// result says it measured nothing instead of returning numbers no person saw.

import { percentile, round2, summary } from "./perf";

/** The record kinds the capture reports apart; any other kind is `other`. */
export const CAPTURE_KINDS = ["tool_call", "tool_call_update", "agent_message_chunk", "other"] as const;
export type CaptureKind = (typeof CAPTURE_KINDS)[number];

/** The longest capture the page runs, in seconds (the app's method and the CLI cap it too). */
export const MAX_CAPTURE_SECONDS = 60;

/** `kind` of a record (`EventRecord.kind`, the ACP `sessionUpdate`), as the capture groups it. */
export function captureKind(kind: unknown): CaptureKind {
  return kind === "tool_call" || kind === "tool_call_update" || kind === "agent_message_chunk" ? kind : "other";
}

/** One record of the selected chat: arrival, time spent applying it, and when its first frame painted. */
export type ArrivalSample = { kind: CaptureKind; apply: number; paint: number };

/** Arrival-to-paint and apply time by kind, plus every kind together under `all`. */
export function arrivalSummary(samples: readonly ArrivalSample[]) {
  const group = (picked: readonly ArrivalSample[]) => ({
    count: picked.length,
    to_paint: summary(picked.map((sample) => sample.paint)),
    apply: summary(picked.map((sample) => sample.apply)),
  });
  const byKind = Object.fromEntries(
    CAPTURE_KINDS.map((kind) => [kind, group(samples.filter((sample) => sample.kind === kind))]),
  ) as Record<CaptureKind, ReturnType<typeof group>>;
  return { all: group(samples), ...byKind };
}

/** Frame intervals from frame-callback timestamps: count, percentiles, and frames past 33 and 50 ms. */
export function frameSummary(timestamps: readonly number[]) {
  const intervals: number[] = [];
  for (let index = 1; index < timestamps.length; index += 1) intervals.push(timestamps[index] - timestamps[index - 1]);
  intervals.sort((a, b) => a - b);
  return {
    count: timestamps.length,
    interval_p50_ms: round2(percentile(intervals, 0.5)),
    interval_p95_ms: round2(percentile(intervals, 0.95)),
    interval_p99_ms: round2(percentile(intervals, 0.99)),
    interval_max_ms: round2(intervals.at(-1) ?? 0),
    over_33_ms: intervals.filter((interval) => interval > 33).length,
    over_50_ms: intervals.filter((interval) => interval > 50).length,
  };
}

/** The parts of a `long-animation-frame` script entry the capture reads (never page text). */
export type LoafScript = { invoker?: string; sourceURL?: string; sourceFunctionName?: string; duration?: number };
/** A `long-animation-frame` or `longtask` entry, as far as the capture reads it. */
export type LongEntry = { duration: number; blockingDuration?: number; scripts?: readonly LoafScript[] };

/** A script URL without its query or fragment, so no parameter a page carries is reported. */
export function scriptSource(url: string | undefined): string {
  if (!url) return "";
  const cut = url.search(/[?#]/);
  return cut < 0 ? url : url.slice(0, cut);
}

/** Long frames or tasks: how many, the longest, and the scripts that blocked longest in them. */
export function longTaskSummary(entries: readonly LongEntry[], source: "long-animation-frame" | "longtask" | null, top = 5) {
  const scripts = new Map<string, { invoker: string; source_url: string; function: string; count: number; total: number; max: number }>();
  for (const entry of entries)
    for (const script of entry.scripts ?? []) {
      const invoker = String(script.invoker ?? "");
      const sourceUrl = scriptSource(script.sourceURL);
      const name = String(script.sourceFunctionName ?? "");
      const key = `${invoker}\u0000${sourceUrl}\u0000${name}`;
      const duration = Number(script.duration) || 0;
      const seen = scripts.get(key) ?? { invoker, source_url: sourceUrl, function: name, count: 0, total: 0, max: 0 };
      seen.count += 1;
      seen.total += duration;
      seen.max = Math.max(seen.max, duration);
      scripts.set(key, seen);
    }
  return {
    source,
    count: entries.length,
    longest_ms: round2(entries.reduce((longest, entry) => Math.max(longest, entry.duration), 0)),
    total_ms: round2(entries.reduce((total, entry) => total + entry.duration, 0)),
    blocking_ms: round2(entries.reduce((total, entry) => total + (entry.blockingDuration ?? 0), 0)),
    top_scripts: [...scripts.values()]
      .sort((a, b) => b.total - a.total)
      .slice(0, top)
      .map(({ total, max, ...script }) => ({ ...script, total_ms: round2(total), max_ms: round2(max) })),
  };
}

/** Layout shifts not caused by input: their summed score and how many. */
export function layoutShiftSummary(entries: readonly { value: number; hadRecentInput?: boolean }[]) {
  const counted = entries.filter((entry) => !entry.hadRecentInput);
  return {
    count: counted.length,
    sum: Math.round(counted.reduce((total, entry) => total + entry.value, 0) * 10_000) / 10_000,
  };
}

/** The page's visibility over the capture, from its samples (`at` in ms, in order). */
export function visibilitySummary(samples: readonly { at: number; state: string }[], end: number) {
  let hidden = 0;
  for (let index = 0; index < samples.length; index += 1) {
    const until = index + 1 < samples.length ? samples[index + 1].at : end;
    if (samples[index].state !== "visible") hidden += Math.max(0, until - samples[index].at);
  }
  return {
    start: samples[0]?.state ?? "unknown",
    end: samples.at(-1)?.state ?? "unknown",
    changes: Math.max(0, samples.length - 1),
    hidden_ms: round2(hidden),
  };
}

/**
 * Whether the numbers show what a person saw: `page_hidden` when the page was hidden for more than
 * half the window, `no_frames` when it drew under one frame a second (a covered window, or a page
 * the app stopped drawing); null when they do.
 */
export function unmeasuredReason(
  seconds: number,
  frames: number,
  visibility: { hidden_ms: number },
): "page_hidden" | "no_frames" | null {
  if (visibility.hidden_ms > (seconds * 1000) / 2) return "page_hidden";
  if (frames < Math.max(2, seconds)) return "no_frames";
  return null;
}

/** What a capture needs from the page; tests pass fakes. */
export type CaptureEnv = {
  now(): number;
  requestFrame(callback: (time: number) => void): number;
  cancelFrame(handle: number): void;
  setTimer(callback: () => void, ms: number): unknown;
  clearTimer(handle: unknown): void;
  /** A port pair: a message posted on `post` runs `onMessage` as a task. */
  channel(onMessage: () => void): { post(): void; close(): void };
  visibility(): string;
  onVisibilityChange(listener: () => void): () => void;
  /** Starts an observer of `type`, or returns undefined when the page has none. */
  observe(type: string, onEntries: (entries: unknown[]) => void): { disconnect(): void } | undefined;
  supportedEntryTypes(): readonly string[];
};

/** The page's own environment. */
export function browserEnv(): CaptureEnv {
  return {
    now: () => performance.now(),
    requestFrame: (callback) => requestAnimationFrame(callback),
    cancelFrame: (handle) => cancelAnimationFrame(handle),
    setTimer: (callback, ms) => setTimeout(callback, ms),
    clearTimer: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
    channel(onMessage) {
      const channel = new MessageChannel();
      channel.port1.onmessage = onMessage;
      return {
        post: () => channel.port2.postMessage(0),
        close() {
          channel.port1.onmessage = null;
          channel.port1.close();
          channel.port2.close();
        },
      };
    },
    visibility: () => document.visibilityState,
    onVisibilityChange(listener) {
      document.addEventListener("visibilitychange", listener);
      return () => document.removeEventListener("visibilitychange", listener);
    },
    observe(type, onEntries) {
      if (typeof PerformanceObserver === "undefined") return undefined;
      try {
        const observer = new PerformanceObserver((list) => onEntries(list.getEntries()));
        observer.observe({ type, buffered: false });
        return observer;
      } catch {
        return undefined;
      }
    },
    supportedEntryTypes: () =>
      typeof PerformanceObserver === "undefined" ? [] : (PerformanceObserver.supportedEntryTypes ?? []),
  };
}

type PendingArrival = { kind: CaptureKind; at: number; apply: number };

/**
 * The page's one capture recorder. The chat client calls `arrived` for each record of the selected
 * chat while `active`; `capture` runs one window and returns its report.
 */
export class ChatPerfCapture {
  /** Read on the event path: false whenever no capture runs. */
  active = false;
  private pending: PendingArrival[] = [];

  /** A record of the selected chat arrived at `at` (before it was applied) and was applied by now. */
  arrived(kind: unknown, at: number, now = performance.now()): void {
    if (!this.active) return;
    this.pending.push({ kind: captureKind(kind), at, apply: now - at });
  }

  async capture(options: { seconds?: unknown } = {}, env: CaptureEnv = browserEnv()): Promise<Record<string, unknown>> {
    if (this.active) return { error: "capture_running" };
    const requested = Number(options.seconds);
    const seconds = Number.isFinite(requested) ? Math.min(MAX_CAPTURE_SECONDS, Math.max(1, requested)) : 5;
    this.active = true;
    this.pending = [];
    const frames: number[] = [];
    const arrivals: ArrivalSample[] = [];
    // Records each frame took in, oldest first; the frame's posted message reads them after it paints.
    const painting: PendingArrival[][] = [];
    const longEntries: LongEntry[] = [];
    const shifts: { value: number; hadRecentInput?: boolean }[] = [];
    const visibility: { at: number; state: string }[] = [];
    const cleanups: (() => void)[] = [];
    const start = env.now();
    visibility.push({ at: start, state: env.visibility() });
    try {
      const channel = env.channel(() => {
        const painted = env.now();
        for (const arrival of painting.shift() ?? [])
          arrivals.push({ kind: arrival.kind, apply: arrival.apply, paint: painted - arrival.at });
      });
      cleanups.push(() => channel.close());
      let frame = 0;
      const onFrame = (time: number) => {
        frames.push(time);
        if (this.pending.length) {
          painting.push(this.pending);
          this.pending = [];
          channel.post();
        }
        frame = env.requestFrame(onFrame);
      };
      frame = env.requestFrame(onFrame);
      cleanups.push(() => env.cancelFrame(frame));
      cleanups.push(env.onVisibilityChange(() => visibility.push({ at: env.now(), state: env.visibility() })));
      const types = env.supportedEntryTypes();
      const longType = types.includes("long-animation-frame") ? "long-animation-frame" : types.includes("longtask") ? "longtask" : null;
      if (longType) {
        const observer = env.observe(longType, (entries) => longEntries.push(...(entries as LongEntry[])));
        if (observer) cleanups.push(() => observer.disconnect());
      }
      const shiftObserver = types.includes("layout-shift")
        ? env.observe("layout-shift", (entries) => shifts.push(...(entries as { value: number; hadRecentInput?: boolean }[])))
        : undefined;
      if (shiftObserver) cleanups.push(() => shiftObserver.disconnect());
      await new Promise<void>((resolve) => {
        const timer = env.setTimer(resolve, seconds * 1000);
        cleanups.push(() => env.clearTimer(timer));
      });
      const end = env.now();
      visibility.push({ at: end, state: env.visibility() });
      const visible = visibilitySummary(visibility, end);
      const frameReport = frameSummary(frames);
      const reason = unmeasuredReason(seconds, frames.length, visible);
      // Records still waiting for a frame never painted inside the window.
      const unpainted = this.pending.length + painting.reduce((total, batch) => total + batch.length, 0);
      return {
        seconds,
        duration_ms: round2(end - start),
        measured: reason === null,
        unmeasured_reason: reason,
        visibility: visible,
        frames: frameReport,
        long_tasks: longTaskSummary(longEntries, longType as "long-animation-frame" | "longtask" | null),
        layout_shift: layoutShiftSummary(shifts),
        records: { ...arrivalSummary(arrivals), unpainted },
      };
    } finally {
      this.active = false;
      this.pending = [];
      for (const cleanup of cleanups.reverse()) cleanup();
    }
  }
}

export const chatPerfCapture = new ChatPerfCapture();
