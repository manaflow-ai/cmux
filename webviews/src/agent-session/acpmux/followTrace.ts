// `debug.agent_pane action=chat_state` reads `follow`: where the transcript sits against its latest
// row, and the recent scrolls that stopped it following, with how long before each the reader
// last touched it (wheel, pointer, touch or key). A scroll that left the latest row with no input
// near it was not the reader's.
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

const stops: FollowStop[] = [];
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
  snapshot() {
    return {
      following,
      scrollTop: scroller?.scrollTop ?? null,
      clientHeight: scroller?.clientHeight ?? null,
      scrollHeight: scroller?.scrollHeight ?? null,
      totalHeight: total,
      programmaticSets: programmatic,
      stops: [...stops],
    };
  },
};
