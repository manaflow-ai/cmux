import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  FOLLOW_EVENT_SAMPLES,
  FOLLOW_STATE_SAMPLES,
  INITIAL_FOLLOW,
  followHeld,
  followRequested,
  followTable,
  isFollowing,
  stepFollow,
  type FollowEvent,
  type FollowEventType,
  type FollowKind,
  type FollowState,
} from "./followState";

const TABLE = join(import.meta.dir, "../../../../../schemas/transcript-follow/table.json");

/// Every state kind and event type, typed so a new one fails to compile here until it is listed.
const KINDS = { following: 0, held: 0, reading: 0, jumping: 0 } satisfies Record<FollowKind, 0>;
const TYPES = {
  growAbove: 0,
  growBelow: 0,
  resize: 0,
  wheel: 0,
  userScroll: 0,
  follow: 0,
  unfollow: 0,
  send: 0,
  jump: 0,
  jumpEnded: 0,
  intentExpired: 0,
  sessionSwitched: 0,
} satisfies Record<FollowEventType, 0>;

/// What each (state kind, event sample) pair does: the outcome or the refusal, and the kind it ends
/// in. Written out by hand, so a change to the machine is a change to this test.
const EXPECTED: Record<string, Record<string, string>> = {
  following: {
    growAbove: "settle following",
    "growAbove(held)": "hold held",
    growBelow: "settle following",
    "growBelow(held)": "hold held",
    resize: "settle following",
    "resize(held)": "hold held",
    "wheel(same)": "kept following",
    "wheel(newer)": "kept following",
    "userScroll(latest)": "kept following",
    "userScroll(away)": "unfollowed reading",
    follow: "kept following",
    "follow(request)": "requested following",
    unfollow: "unfollowed reading",
    send: "requested following",
    jump: "jumped jumping",
    jumpEnded: "!not_jumping following",
    "intentExpired(stale)": "!not_held following",
    intentExpired: "!not_held following",
    sessionSwitched: "forgot following",
  },
  held: {
    growAbove: "settle following",
    "growAbove(held)": "hold held",
    growBelow: "settle following",
    "growBelow(held)": "hold held",
    resize: "settle following",
    "resize(held)": "hold held",
    "wheel(same)": "kept held",
    "wheel(newer)": "kept held",
    "userScroll(latest)": "kept held",
    "userScroll(away)": "unfollowed reading",
    follow: "kept held",
    "follow(request)": "requested following",
    unfollow: "unfollowed reading",
    send: "requested following",
    jump: "jumped jumping",
    jumpEnded: "!not_jumping held",
    "intentExpired(stale)": "!stale_generation held",
    intentExpired: "resume following",
    sessionSwitched: "forgot following",
  },
  reading: {
    growAbove: "anchor reading",
    "growAbove(held)": "anchor reading",
    growBelow: "anchor reading",
    "growBelow(held)": "anchor reading",
    resize: "anchor reading",
    "resize(held)": "anchor reading",
    "wheel(same)": "kept reading",
    "wheel(newer)": "kept reading",
    "userScroll(latest)": "followed following",
    "userScroll(away)": "rested reading",
    follow: "followed following",
    "follow(request)": "followed following",
    unfollow: "unfollowed reading",
    send: "followed following",
    jump: "jumped jumping",
    jumpEnded: "!not_jumping reading",
    "intentExpired(stale)": "!not_held reading",
    intentExpired: "!not_held reading",
    sessionSwitched: "forgot reading",
  },
  jumping: {
    growAbove: "retarget jumping",
    "growAbove(held)": "retarget jumping",
    growBelow: "retarget jumping",
    "growBelow(held)": "retarget jumping",
    resize: "retarget jumping",
    "resize(held)": "retarget jumping",
    "wheel(same)": "kept jumping",
    "wheel(newer)": "kept jumping",
    "userScroll(latest)": "kept jumping",
    "userScroll(away)": "!jumping jumping",
    follow: "kept jumping",
    "follow(request)": "requested jumping",
    unfollow: "!jumping jumping",
    send: "requested jumping",
    jump: "jumped jumping",
    jumpEnded: "landed following",
    "intentExpired(stale)": "!not_held jumping",
    intentExpired: "!not_held jumping",
    sessionSwitched: "forgot jumping",
  },
};

// An ask made at the pass's input generation follows through the reader's hold.
EXPECTED["following(request)"] = {
  ...EXPECTED.following!,
  "growAbove(held)": "settle following",
  "growBelow(held)": "settle following",
  "resize(held)": "settle following",
};
EXPECTED["jumping(request)"] = EXPECTED.jumping!;

test("every state x event pair is a named transition or a named refusal", () => {
  const sampledKinds = new Set(Object.values(FOLLOW_STATE_SAMPLES).map((state) => state.kind));
  const sampledTypes = new Set(Object.values(FOLLOW_EVENT_SAMPLES).map((event) => event.type));
  expect([...sampledKinds].sort()).toEqual(Object.keys(KINDS).sort());
  expect([...sampledTypes].sort()).toEqual(Object.keys(TYPES).sort());
  for (const [name, state] of Object.entries(FOLLOW_STATE_SAMPLES))
    for (const [event, input] of Object.entries(FOLLOW_EVENT_SAMPLES)) {
      const step = stepFollow(state, input);
      const got = `${"refusal" in step ? `!${step.refusal}` : step.outcome} ${step.state.kind}`;
      expect({ pair: `${name} x ${event}`, got }).toEqual({ pair: `${name} x ${event}`, got: EXPECTED[name]![event]! });
      // A refusal leaves the machine as it was.
      if ("refusal" in step) expect(step.state).toBe(state);
    }
});

test("asks to follow lapse at the next input and are kept through a ride", () => {
  let state = stepFollow(INITIAL_FOLLOW, { type: "send", generation: 4 }).state;
  expect(followRequested(state, 4)).toBe(true);
  expect(followHeld(state, 4, true)).toBe(false);
  state = stepFollow(state, { type: "jump", target: 500 }).state;
  expect(followRequested(state, 4)).toBe(true);
  // A ride always holds the pass's settle: it owns the offset.
  expect(followHeld(state, 4, false)).toBe(true);
  state = stepFollow(state, { type: "jumpEnded" }).state;
  expect(state).toEqual({ kind: "following", request: 4 });
  state = stepFollow(state, { type: "wheel", generation: 5 }).state;
  expect(followRequested(state, 5)).toBe(false);
  expect(followHeld(state, 5, true)).toBe(true);
});

test("the committed table is the machine's (schemas/transcript-follow/table.json)", () => {
  const committed = JSON.parse(readFileSync(TABLE, "utf8"));
  const live = followTable();
  if (process.env.UPDATE_FOLLOW_TABLE) {
    require("node:fs").writeFileSync(TABLE, `${JSON.stringify(live, null, 2)}\n`);
    return;
  }
  // Stale: regenerate with UPDATE_FOLLOW_TABLE=1 bun test followState.test.ts.
  expect(committed).toEqual(live);
});

// --- The fake layout: rows as heights, a viewport, an offset, as the transcript keeps them. ---

type Row = { id: string; height: number };
type Layout = { rows: Row[]; viewport: number; top: number };

const total = (layout: Layout) => layout.rows.reduce((sum, row) => sum + row.height, 0);
const latestOf = (layout: Layout) => Math.max(0, total(layout) - layout.viewport);
const topOf = (layout: Layout, id: string) => {
  let top = 0;
  for (const row of layout.rows) {
    if (row.id === id) return top;
    top += row.height;
  }
  return Number.NaN;
};
/// The first row the view shows, and how far the view's top is into it.
const anchorOf = (layout: Layout) => {
  let top = 0;
  for (const row of layout.rows) {
    if (top + row.height > layout.top) return { id: row.id, into: layout.top - top };
    top += row.height;
  }
  return undefined;
};

/// A seeded generator (mulberry32), so a failure replays.
function random(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// The transcript in miniature: the input hold's generations and timer as userScroll.ts keeps them
/// (an input issues a timer under a new hold generation; only the newest one's firing ends it), and
/// a placement pass that does what VirtualTranscript's does with the machine's outcome.
function transcript(seed: number) {
  const next = random(seed);
  let ids = 0;
  const row = (): Row => ({ id: `r${ids++}`, height: 20 + Math.floor(next() * 200) });
  const layout: Layout = { rows: Array.from({ length: 12 }, row), viewport: 300, top: 0 };
  layout.top = latestOf(layout);
  let state: FollowState = INITIAL_FOLLOW;
  let input = 0;
  let hold = 0;
  /// The hold timer pending, by the hold generation it was issued under.
  let timer: number | undefined;
  const step = (event: FollowEvent) => {
    const result = stepFollow(state, event);
    state = result.state;
    return result;
  };
  const markInput = () => {
    input += 1;
    hold += 1;
    timer = hold;
    step({ type: "wheel", generation: input });
  };
  const pass = (type: "growAbove" | "growBelow" | "resize", anchor: ReturnType<typeof anchorOf>) => {
    const latest = latestOf(layout);
    const result = step({ type, top: layout.top, latest, input, hold: timer === undefined ? undefined : hold });
    const outcome = "outcome" in result ? result.outcome : undefined;
    if (outcome === "settle") layout.top = latest;
    // The anchor pass (preserveScrollAnchorTop): the row at the view's top keeps where it is drawn.
    // The scroller clamps an offset past its end (a viewport that grew under a reader near it).
    let clamped = false;
    if (outcome === "anchor" && anchor) {
      const kept = Math.max(0, topOf(layout, anchor.id) + anchor.into);
      clamped = kept > latest;
      layout.top = Math.min(kept, latest);
    }
    // Any other state leaves the offset to the scroller, clamped to its end.
    if (outcome !== "anchor" && layout.top > latest) layout.top = latest;
    // A ride retargets and keeps gliding; it lands on the moved end when it ends.
    return { outcome, clamped };
  };
  return {
    layout,
    get state() {
      return state;
    },
    next,
    row,
    pass,
    markInput,
    step,
    /// The hold's timer fires: as its event, carrying its generation.
    expire() {
      if (timer === undefined) return;
      const issued = timer;
      timer = undefined;
      const result = step({ type: "intentExpired", generation: issued });
      if ("outcome" in result && result.outcome === "resume") pass("growBelow", anchorOf(layout));
      return result;
    },
    /// The scroll handler: the reader's offset, at the latest row or not.
    scrolled() {
      const atLatest = layout.top >= latestOf(layout) - 4;
      const anchor = anchorOf(layout);
      step({ type: "userScroll", atLatest, anchorRow: anchor?.id, offset: layout.top });
    },
    input: () => input,
  };
}

test("random walk: the anchor moves 0 px while Reading, the bottom gap stays within 4 px while Following", () => {
  for (let seed = 1; seed <= 200; seed += 1) {
    const view = transcript(seed);
    const { layout } = view;
    for (let at = 0; at < 300; at += 1) {
      const anchor = anchorOf(layout);
      const anchorDrawn = anchor ? topOf(layout, anchor.id) - layout.top : 0;
      const pick = view.next();
      let laidOut: "growAbove" | "growBelow" | "resize" | undefined;
      if (pick < 0.2) {
        // Older rows land above.
        layout.rows.unshift(...Array.from({ length: 1 + Math.floor(view.next() * 3) }, view.row));
        laidOut = "growAbove";
      } else if (pick < 0.45) {
        // A reply streams: the last row grows, or a row arrives below.
        if (view.next() < 0.5) layout.rows[layout.rows.length - 1]!.height += 1 + Math.floor(view.next() * 60);
        else layout.rows.push(view.row());
        laidOut = "growBelow";
      } else if (pick < 0.55) {
        layout.viewport = 150 + Math.floor(view.next() * 400);
        laidOut = "resize";
      } else if (pick < 0.75) {
        // A wheel: the reader's input, then the offset it moved and its scroll event.
        view.markInput();
        const delta = Math.round((view.next() - 0.6) * 400);
        layout.top = Math.max(0, Math.min(latestOf(layout), layout.top + delta));
        view.scrolled();
      } else if (pick < 0.82) {
        // A send: to the latest row through the hold, with its row below.
        view.step({ type: "send", generation: view.input() });
        layout.rows.push(view.row());
        laidOut = "growBelow";
      } else if (pick < 0.86) {
        view.step({ type: "jump", target: latestOf(layout) });
      } else if (pick < 0.9) {
        // The ride lands at the end it was retargeted to.
        if (view.state.kind === "jumping") {
          layout.top = latestOf(layout);
          view.step({ type: "jumpEnded" });
        }
      } else view.expire();
      if (laidOut) {
        const before = view.state;
        const { outcome, clamped } = view.pass(laidOut, anchor);
        if (before.kind === "reading" && !clamped) {
          // The anchor row is drawn where it was: 0 px.
          expect({ seed, at, moved: anchor ? topOf(layout, anchor.id) - layout.top - anchorDrawn : 0 }).toEqual({
            seed,
            at,
            moved: 0,
          });
        }
        if (outcome === "settle")
          expect({ seed, at, gap: Math.abs(latestOf(layout) - layout.top) <= 4 }).toEqual({ seed, at, gap: true });
      }
      // Following and not held by the reader's input nor riding: the bottom gap is within 4 px.
      if (view.state.kind === "following" && laidOut)
        expect({ seed, at, gap: latestOf(layout) - layout.top }).toEqual({
          seed,
          at,
          gap: Math.min(4, Math.max(-4, latestOf(layout) - layout.top)),
        });
      expect(isFollowing(view.state)).toBe(view.state.kind !== "reading");
    }
  }
});
