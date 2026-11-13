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

test("switching the running status line does not end its turn", () => {
  const running = [row("u", "user"), row("working-u", "working"), row(LIVE_THINKING, "thinking")];
  const status = [row("u", "user"), row("activityLine-u", "activityLine")];
  expect(hasLiveLine(status)).toBe(true);
  expect(endsTurn(running, status)).toBe(false);
  expect(endsTurn(status, running)).toBe(false);
  expect(endsTurn(status, [row("u", "user"), row("worked-u", "worked"), row("answer")])).toBe(true);
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

test("folded work stays between the header and final answer while they move", async () => {
  const { JSDOM } = await import("jsdom");
  const { captureTurnEnd, playTurnEnd, settleTurnEnd } = await import("./turnEndFold");
  const dom = new JSDOM("<!doctype html><main></main>", { pretendToBeVisual: true });
  const thread = dom.window.document.querySelector<HTMLElement>("main")!;
  const proto = dom.window.HTMLElement.prototype;
  Object.defineProperty(proto, "offsetTop", {
    get() {
      return Number.parseFloat(this.style.top) || 0;
    },
  });
  Object.defineProperty(proto, "offsetHeight", {
    get() {
      return Number.parseFloat(this.style.height) || 0;
    },
  });
  proto.getBoundingClientRect = function () {
    return {
      top: this.offsetTop,
      bottom: this.offsetTop + this.offsetHeight,
      height: this.offsetHeight,
      left: 0,
      right: 100,
      width: 100,
      x: 0,
      y: this.offsetTop,
      toJSON() {},
    };
  };
  const frames = new Map<HTMLElement, Keyframe[]>();
  proto.animate = function (keyframes) {
    frames.set(this, keyframes as Keyframe[]);
    return { cancel() {}, finish() {} } as Animation;
  };
  const draw = (id: string, kind: string, top: number, height: number) => {
    const node = dom.window.document.createElement("article");
    node.className = `acpmux-row acpmux-${kind}`;
    node.dataset.rowId = id;
    node.style.top = `${top}px`;
    node.style.height = `${height}px`;
    thread.append(node);
    return node;
  };
  draw("working-u", "working", 0, 34);
  draw("work", "activity", 34, 60);
  draw("answer", "assistant", 94, 50);
  draw(LIVE_THINKING, "thinking", 144, 22);
  const capture = captureTurnEnd(thread, thread, [row("worked-u", "worked"), row("answer")], "chat")!;
  expect(capture.rows.find((entry) => entry.id === "worked-u")?.copy).toBeUndefined();
  expect(capture.rows.some((entry) => entry.id === "worked-u")).toBe(true);
  const copy = capture.rows.find((entry) => entry.id === "work")!.copy!;
  thread.replaceChildren();
  draw("worked-u", "worked", 100, 34);
  draw("answer", "assistant", 134, 50);
  const fold = playTurnEnd(thread, capture, "chat")!;
  try {
    const motion = frames.get(copy)!;
    expect(motion).toBeDefined();
    expect(motion[0]!.clipPath).toBe("inset(0px -4096px 0px -4096px)");
    expect(motion.at(-1)!.clipPath).toBe("inset(0px -4096px 60px -4096px)");
    expect(motion.at(-1)!.translate).toBe("0 100px");
    const header = frames.get(thread.querySelector('[data-row-id="worked-u"]') as HTMLElement)!;
    const answer = frames.get(thread.querySelector('[data-row-id="answer"]') as HTMLElement)!;
    const interpolate = (from: number, to: number, progress: number) => from + (to - from) * progress;
    const translated = (motion: Keyframe[], progress: number) =>
      interpolate(
        Number.parseFloat(String(motion[0]!.translate).split(" ")[1]!),
        Number.parseFloat(String(motion.at(-1)!.translate).split(" ")[1]!),
        progress,
      );
    const clipped = (frame: Keyframe) => Number.parseFloat(String(frame.clipPath).split(" ")[2]!);
    for (const progress of [0, 0.25, 0.5, 0.75, 1]) {
      const top = copy.offsetTop + translated(motion, progress);
      const bottom = top + copy.offsetHeight - interpolate(clipped(motion[0]!), clipped(motion.at(-1)!), progress);
      expect(top).toBeGreaterThanOrEqual(100 + translated(header, progress) + 34);
      expect(bottom).toBeLessThanOrEqual(134 + translated(answer, progress));
    }
  } finally {
    settleTurnEnd(thread, fold);
    dom.window.close();
  }
});

test("a long fold resolves on the settle, its frames under the bound up to what the straight line fits", async () => {
  // Leo, 2026-11-11, on the long fold that ran up to 1.2 s: "It looks like the f***ing Star Wars
  // scroll-up animation ... it should not be slow." Every fold now ends with the settle; review of
  // #40350 (F1) still holds where the straight line can: no 120 Hz frame past the bound.
  const { turnEndFoldTiming } = await import("./turnEndFold");
  const { bezierAt, parseBezier } = await import("../../../ui/cubicBezier");
  const { currentChatMetrics } = await import("../chatDisplay");
  const { ARRIVAL_FRAME_LINES } = await import("./followChase");
  const { MOTION_SETTLE, MOTION_SETTLE_MS } = await import("../../../motion/scale.generated");
  const line = currentChatMetrics().lineHeight;
  const frame = 1000 / 120;
  for (const px of [100, 274, 290, 800, 2000]) {
    const { ms, easing } = turnEndFoldTiming(px, MOTION_SETTLE_MS, MOTION_SETTLE);
    const curve = parseBezier(easing);
    expect(curve).toBeDefined();
    // Never longer than the settle, however far it moves.
    expect(ms).toBe(MOTION_SETTLE_MS);
    const drawn = (t: number) => px * bezierAt(curve!, Math.min(1, t / ms));
    expect(drawn(ms)).toBeCloseTo(px, 6);
    if (px > 290) continue;
    for (let t = frame; t < ms + frame; t += frame)
      expect(drawn(t) - drawn(t - frame)).toBeLessThanOrEqual(ARRIVAL_FRAME_LINES * line + 1e-6);
  }
  // A short fold keeps the settle as it is.
  expect(turnEndFoldTiming(40, MOTION_SETTLE_MS, MOTION_SETTLE)).toEqual({
    ms: MOTION_SETTLE_MS,
    easing: MOTION_SETTLE,
  });
});

test("the fold's curve search picks the least lean that fits, and the straight line past it", async () => {
  const { turnEndFoldTiming } = await import("./turnEndFold");
  const { MOTION_SETTLE, MOTION_SETTLE_MS } = await import("../../../motion/scale.generated");
  const timing = (px: number) => turnEndFoldTiming(px, MOTION_SETTLE_MS, MOTION_SETTLE);
  expect(timing(100)).toEqual({ ms: 180, easing: "cubic-bezier(0.236, 0.708, 0.46, 0.854)" });
  expect(timing(274)).toEqual({ ms: 180, easing: "cubic-bezier(0.328, 0.354, 0.655, 0.677)" });
  expect(timing(800)).toEqual({ ms: 180, easing: "cubic-bezier(0.333, 0.333, 0.667, 0.667)" });
  expect(timing(2000)).toEqual({ ms: 180, easing: "cubic-bezier(0.333, 0.333, 0.667, 0.667)" });
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
