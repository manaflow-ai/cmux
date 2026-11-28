// The chat page's half of the always-on frame tally (acpmux frame_tally.rs): the gaps between the
// display frames the chat drew while it worked, counted into fixed buckets and sent to the daemon at
// most every FLUSH_MS as `_acpmux/perf {op:"tally"}`. `cmux debug perf frames` reads the last
// 5 minutes as p50/p95/p99; perf-tap publishes the p95 as NOW's perf_sensor.leo_nightly.frame_p95_ms,
// the number of the goal "the visible chat draws at p95 <= 16.7 ms per frame while the Mac's load is at
// least 4x its cores" (Leo, 2026-11-22 08:31Z: "so you need to figure out a non-spammy way for this to
// essentially be an automatic, constant, recurrent pursuit").
//
// The gaps come from the frame loop the chat already runs (frameBudget.ts), which runs only while the
// chat does work and only while the page is visible: an idle or hidden chat counts nothing and asks for
// no frame. Cost: one array add per frame, and at most one timer and one small request per FLUSH_MS while
// frames come; none while they do not. A send the daemon refuses or loses is dropped (the tally is a
// sample, never a log), and after FAILURES_TO_STOP in a row the tally stops sending for good.

import { slackTimersFor } from "../../../pages/shared/slackTimers";

/** Sends one `_acpmux/perf` request (the page's client, direct.ts `perf`). */
export type TallySend = (params: Record<string, unknown>) => Promise<unknown>;

/** The width of one bucket (ms); frame_tally.rs BUCKET_MS, which refuses any other. */
export const BUCKET_MS = 0.1;
/** Buckets up to BUCKETS * BUCKET_MS (100 ms); one more holds every longer gap. */
export const BUCKETS = 1000;
/** How often a tally goes at most, while frames come (ms). */
export const FLUSH_MS = 5_000;
/** A gap past this is the page coming back from hidden or a machine asleep, not a frame (ms). */
const AWAY_GAP_MS = 5_000;
/** Sends that failed in a row before the tally stops (the page lost its daemon for good). */
const FAILURES_TO_STOP = 30;

type Later = (callback: () => void, ms: number) => unknown;

export class FrameTally {
  private counts = new Map<number, number>();
  private send: TallySend | undefined;
  private pending = false;
  private failures = 0;

  // By default on the page's shared timer with a whole period of slack (a sample can go late): the
  // flush rides a heartbeat, or the beat that rests the page, instead of waking a chat at rest by itself
  // (slackTimers.ts).
  constructor(
    private readonly later: Later = (callback, ms) => slackTimersFor().later(callback, ms, ms, { atRest: true }),
  ) {}

  /** Sends through `send` from now on (the page's client once it connects; a new one replaces it). */
  attach(send: TallySend): void {
    if (this.failures >= FAILURES_TO_STOP) return;
    this.send = send;
    this.schedule();
  }

  /** One display frame `gap` ms after the one before, drawn while the chat worked. */
  note(gap: number): void {
    if (!(gap > 0) || gap >= AWAY_GAP_MS || this.failures >= FAILURES_TO_STOP) return;
    const index = Math.min(BUCKETS, Math.floor(gap / BUCKET_MS + 1e-9));
    this.counts.set(index, (this.counts.get(index) ?? 0) + 1);
    this.schedule();
  }

  /** The buckets held now, as `[index, count]` pairs (for tests and the flush). */
  held(): [number, number][] {
    return [...this.counts.entries()].sort((a, b) => a[0] - b[0]);
  }

  /** Sends what is held now and empties it. */
  flush(): void {
    this.pending = false;
    const send = this.send;
    if (!send || this.counts.size === 0) return;
    const gaps = this.held();
    this.counts = new Map();
    let sent: Promise<unknown>;
    try {
      sent = Promise.resolve(send({ op: "tally", bucketMs: BUCKET_MS, gaps }));
    } catch (error) {
      sent = Promise.reject(error);
    }
    sent.then(
      () => {
        this.failures = 0;
      },
      () => {
        this.failures += 1;
        if (this.failures >= FAILURES_TO_STOP) {
          this.send = undefined;
          this.counts = new Map();
        }
      },
    );
  }

  private schedule(): void {
    if (this.pending || !this.send || this.counts.size === 0) return;
    this.pending = true;
    this.later(() => this.flush(), FLUSH_MS);
  }
}

/** The page's one tally: frameBudget.ts notes into it, App.tsx attaches the connected client. */
export const frameTally = new FrameTally();
