// `debug.agent_pane action=chat_state` reads `follow`: where the transcript sits against its latest
// row, and the recent scrolls that stopped it following, with how long before each the reader
// last touched it (wheel, pointer, touch or key). A scroll that left the latest row with no input
// near it was not the reader's. `arms` says what turned following back on, and with which input.
export type FollowStop = {
  at: number;
  top: number;
  previous: number;
  latest: number;
  scrollHeight: number;
  clientHeight: number;
  inputAgoMs: number | null;
  /** How many sets ago the transcript itself set this offset; null when it never did lately. */
  setsAgo: number | null;
};

/// Why the transcript began following its latest row again: the path that turned it on and, for the
/// reader's own scroll, the input that moved it there (Leo, 2026-11-07: scrolled up, he was sent to
/// the bottom while only hovering). Only explicit actions and the reader's downward scroll arm it.
export type FollowArm = {
  at: number;
  /** "reader-scroll", "jump", "send", "fold-close", "open", "session" or another named path. */
  path: string;
  /** The input behind a reader scroll ("wheel 40", "keydown End", "pointermove", "touchmove"). */
  input: string | null;
  inputAgoMs: number | null;
  top: number | null;
};

const stops: FollowStop[] = [];
const arms: FollowArm[] = [];
let lastInput = 0;
let programmatic = 0;
const targets: number[] = [];
let scroller: HTMLElement | null = null;
let total = 0;
let following = true;

export const followTrace = {
  input() {
    lastInput = performance.now();
  },
  set(top: number) {
    programmatic += 1;
    targets.push(top);
    if (targets.length > 16) targets.shift();
  },
  update(node: HTMLElement | null, totalHeight: number, follows: boolean) {
    scroller = node;
    total = totalHeight;
    following = follows;
  },
  stopped(stop: Omit<FollowStop, "at" | "inputAgoMs" | "setsAgo">) {
    const now = performance.now();
    let index = targets.length - 1;
    while (index >= 0 && Math.abs(targets[index]! - stop.top) > 1) index -= 1;
    stops.push({
      ...stop,
      at: Math.round(now),
      inputAgoMs: lastInput ? Math.round(now - lastInput) : null,
      setsAgo: index < 0 ? null : targets.length - 1 - index,
    });
    if (stops.length > 20) stops.shift();
  },
  armed(path: string, input: string | null = null, top: number | null = null) {
    const now = performance.now();
    arms.push({ at: Math.round(now), path, input, inputAgoMs: lastInput ? Math.round(now - lastInput) : null, top });
    if (arms.length > 20) arms.shift();
  },
  snapshot() {
    return {
      following,
      scrollTop: scroller?.scrollTop ?? null,
      clientHeight: scroller?.clientHeight ?? null,
      scrollHeight: scroller?.scrollHeight ?? null,
      totalHeight: total,
      programmaticSets: programmatic,
      stops: [...stops],
      arms: [...arms],
    };
  },
};
