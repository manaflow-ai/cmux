// A turn's end is the update that takes the running turn's line away (turnEndFold.ts): only then
// does the end-of-turn fold play.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { endsTurn, hasLiveLine, turnEndLook } from "./turnEndFold";
import { LIVE_THINKING } from "./turns";

const row = (id: string, kind: AcpmuxRow["kind"] = "assistant"): AcpmuxRow => ({ id, version: 1, at: 1, kind });

test("the running turn's line near the end marks a turn that runs", () => {
  expect(hasLiveLine([row("u", "user"), row(LIVE_THINKING, "thinking")])).toBe(true);
  expect(hasLiveLine([row(LIVE_THINKING, "thinking"), row("date", "system")])).toBe(true);
  expect(hasLiveLine([row("u", "user"), row("a")])).toBe(false);
  // Far from the end it is not the running turn's line.
  expect(hasLiveLine([row(LIVE_THINKING, "thinking"), ...Array.from({ length: 8 }, (_, i) => row(`a${i}`))])).toBe(
    false,
  );
});

test("an update ends the turn only when it takes the line away", () => {
  const running = [row("u", "user"), row("work", "activity"), row(LIVE_THINKING, "thinking")];
  const ended = [row("u", "user"), row("worked-u", "worked"), row("answer")];
  expect(endsTurn(running, ended)).toBe(true);
  expect(endsTurn(running, running)).toBe(false);
  expect(endsTurn(running, [...running.slice(0, 2), row("more", "activity"), row(LIVE_THINKING, "thinking")])).toBe(
    false,
  );
  expect(endsTurn(ended, [...ended, row("b")])).toBe(false);
  expect(endsTurn(undefined, ended)).toBe(false);
  // The transcript cut and drawn again under new ids (Edit forks before the running prompt): the
  // line goes with the prompt, and no turn ended.
  expect(endsTurn(running, [row("u2", "user"), row("worked-u2", "worked"), row("answer")])).toBe(false);
  expect(endsTurn([row("u", "user"), row("p", "user"), row(LIVE_THINKING, "thinking")], [row("u", "user")])).toBe(
    false,
  );
});

test("a user line another agent or the inbox drew is not the turn's prompt", () => {
  // An incoming message's line (model.ts `isLineRow`) after the prompt regroups under a new id as the
  // turn ends: the prompt above it stays, so the turn ended.
  const incoming: AcpmuxRow = { ...row("in-1", "user"), incoming: { kind: "message" } as AcpmuxRow["incoming"] };
  const running = [row("u", "user"), row("work", "activity"), incoming, row(LIVE_THINKING, "thinking")];
  expect(
    endsTurn(running, [row("u", "user"), row("worked-u", "worked"), row("run-in-1", "messageRun"), row("answer")]),
  ).toBe(true);
  // The prompt itself going is still a cut transcript.
  expect(endsTurn(running, [row("u2", "user"), row("worked-u2", "worked"), row("answer")])).toBe(false);
});

test("the look comes from the nearest attribute, else the shipped fade", () => {
  const node = { closest: () => ({ getAttribute: () => "tuck" }) } as unknown as Element;
  expect(turnEndLook(node)).toBe("tuck");
  expect(turnEndLook({ closest: () => null } as unknown as Element)).toBe("fade");
  expect(turnEndLook({ closest: () => ({ getAttribute: () => "spin" }) } as unknown as Element)).toBe("fade");
});

test("a capture from another chat plays nothing and draws nothing of it", async () => {
  const { JSDOM } = await import("jsdom");
  const { playTurnEnd } = await import("./turnEndFold");
  const dom = new JSDOM("<!doctype html><div id=thread></div>", { pretendToBeVisual: true });
  const thread = dom.window.document.getElementById("thread")!;
  const reply = dom.window.document.createElement("div");
  reply.className = "acpmux-row";
  reply.dataset.rowId = "answer";
  thread.append(reply);
  const copy = dom.window.document.createElement("div");
  const capture = {
    rows: [
      { id: LIVE_THINKING, top: 80, copy },
      { id: "answer", top: 40 },
    ],
    scrollTop: 0,
    sessionId: "chat-a",
  };
  // Another chat shown in its place: nothing of chat A is drawn over it, and nothing plays.
  expect(playTurnEnd(thread, capture, "chat-b")).toBeUndefined();
  expect(thread.contains(copy)).toBe(false);
  expect(thread.hasAttribute("data-turn-end-folding")).toBe(false);
  dom.window.close();
});

test("a long fold keeps every 120 Hz frame under the bound, at the duration cap too", async () => {
  // Review of #40350 (F1): at the 720 ms cap a 274 px fold on the settle's curve moved 19.34 px in
  // its first 120 Hz frame, past the two thirds of a line turn-transition-jumps.test.ts holds every
  // transition's frames to.
  const { turnEndFoldTiming } = await import("./turnEndFold");
  const { bezierAt, parseBezier } = await import("../../../ui/cubicBezier");
  const { currentChatMetrics } = await import("../chatDisplay");
  const { ARRIVAL_FRAME_LINES } = await import("./followChase");
  const { MOTION_SETTLE, MOTION_SETTLE_MS } = await import("../../../motion/scale.generated");
  const line = currentChatMetrics().lineHeight;
  const frame = 1000 / 120;
  for (const px of [100, 274, 500, 800]) {
    const { ms, easing } = turnEndFoldTiming(px, MOTION_SETTLE_MS, MOTION_SETTLE);
    const curve = parseBezier(easing);
    expect(curve).toBeDefined();
    // The fold resolves fast: never past four settles for these moves.
    expect(ms).toBeLessThanOrEqual(4 * MOTION_SETTLE_MS + frame);
    const drawn = (t: number) => px * bezierAt(curve!, Math.min(1, t / ms));
    expect(drawn(frame)).toBeLessThanOrEqual(ARRIVAL_FRAME_LINES * line + 1e-6);
    for (let t = frame; t < ms + frame; t += frame)
      expect(drawn(t) - drawn(t - frame)).toBeLessThanOrEqual(ARRIVAL_FRAME_LINES * line + 1e-6);
    expect(drawn(ms)).toBeCloseTo(px, 6);
  }
  // A short fold keeps the settle as it is.
  expect(turnEndFoldTiming(40, MOTION_SETTLE_MS, MOTION_SETTLE)).toEqual({
    ms: MOTION_SETTLE_MS,
    easing: MOTION_SETTLE,
  });
});

test("the fold's curve search keeps the timings it found before", async () => {
  // Review of #40627 (F1): the search ran about 33k curve reads for 274 px. Made constant cost, it
  // still picks the same length and curve.
  const { turnEndFoldTiming } = await import("./turnEndFold");
  const { MOTION_SETTLE, MOTION_SETTLE_MS } = await import("../../../motion/scale.generated");
  const timing = (px: number) => turnEndFoldTiming(px, MOTION_SETTLE_MS, MOTION_SETTLE);
  expect(timing(100)).toEqual({ ms: 372, easing: MOTION_SETTLE });
  expect(timing(274)).toEqual({ ms: 720, easing: "cubic-bezier(0.198, 0.854, 0.38, 0.927)" });
  expect(timing(800)).toEqual({ ms: 720, easing: "cubic-bezier(0.306, 0.437, 0.609, 0.719)" });
  expect(timing(2000)).toEqual({ ms: 1222, easing: "cubic-bezier(0.333, 0.333, 0.667, 0.667)" });
});

test("the fold's curve search for a 2000 px move stays under half a millisecond", async () => {
  // Review of #40627 (F1): the search ran synchronously in the placement pass, 9.6 ms for 274 px and
  // 12.9 ms for 800 px, past the 8.33 ms of a 120 Hz frame it protects. Each run is cold (the memo
  // forgotten), after a warm-up; the median keeps a slow runner's stray pause out.
  const fold = (await import("./turnEndFold")) as typeof import("./turnEndFold") & {
    clearTurnEndFoldMemo?: () => void;
  };
  const { MOTION_SETTLE, MOTION_SETTLE_MS } = await import("../../../motion/scale.generated");
  const run = (px: number) => {
    fold.clearTurnEndFoldMemo?.();
    const start = performance.now();
    fold.turnEndFoldTiming(px, MOTION_SETTLE_MS, MOTION_SETTLE);
    return performance.now() - start;
  };
  for (let index = 0; index < 5; index += 1) run(2000);
  const runs = Array.from({ length: 21 }, () => run(2000)).sort((a, b) => a - b);
  expect(runs[10]!).toBeLessThan(0.5);
});
