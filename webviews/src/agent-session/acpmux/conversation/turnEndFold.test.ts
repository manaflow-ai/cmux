// A turn's end is the update that takes the running turn's line away (turnEndFold.ts): only then
// does the end-of-turn fold play.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { endsTurn, hasLiveLine, turnEndLook, drawsCopy } from "./turnEndFold";
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

test("a turn's end drawn with the next prompt and its line still ends the turn", () => {
  // Shapes from hidden-reshow TURN_TRACE: the ended turn and the next turn's prompt in one render, so
  // `after` has a live line again, under the next prompt (the reply jumped 87 px with no fold).
  const running: AcpmuxRow[] = [
    row("user-5865", "user"),
    { ...row("worked-user-5865", "worked"), turnPhase: "running" },
    row("activity-5868", "activity"),
    row("assistant-5874"),
    row("activity-5877", "activity"),
    row("assistant-5881"),
    row(LIVE_THINKING, "thinking"),
  ];
  const ended = [
    row("user-5865", "user"),
    row("worked-user-5865", "worked"),
    row("assistant-5881"),
    row("summary-turn-247", "turnSummary"),
  ];
  const next = row("user-5886", "user");
  expect(endsTurn(running, [...ended, next])).toBe(true);
  expect(endsTurn(running, [...ended, next, row(LIVE_THINKING, "thinking")])).toBe(true);
  expect(
    endsTurn(running, [
      ...ended,
      next,
      { ...row("worked-user-5886", "worked"), turnPhase: "running" },
      row(LIVE_THINKING, "thinking"),
    ]),
  ).toBe(true);
  // The next prompt another agent's message, drawn as a line (model.ts `isLineRow`).
  const line: AcpmuxRow = { ...next, incoming: { kind: "message" } as AcpmuxRow["incoming"] };
  const lineTurn = [
    { ...row("worked-user-5886", "worked"), turnPhase: "running" },
    line,
    row("activity-5889", "activity"),
    row(LIVE_THINKING, "thinking"),
  ];
  expect(endsTurn(running, [...ended, ...lineTurn])).toBe(true);
  // A turn that had already ended (its Worked for drawn before) ends nothing when the next one runs.
  const endedBefore = [...ended, next, row(LIVE_THINKING, "thinking")];
  expect(
    endsTurn(endedBefore, [
      ...endedBefore.slice(0, -1),
      row("activity-5890", "activity"),
      row(LIVE_THINKING, "thinking"),
    ]),
  ).toBe(false);
  // The ended turn's prompt going with it is still a cut transcript.
  expect(
    endsTurn(running, [row("user-9", "user"), row("worked-user-9", "worked"), next, row(LIVE_THINKING, "thinking")]),
  ).toBe(false);
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
    // A copy also plays its cover clip after its motion (turnEndFold.ts `clipped`): keep the motion.
    const next = keyframes as Keyframe[];
    if (!frames.has(this) || next.some((frame) => frame.translate !== undefined)) frames.set(this, next);
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
  // The turn's header, running: one row with the ended one, its chevron's slot held unseen.
  draw("worked-u", "worked", 0, 34).innerHTML = '<svg class="cv-worked__chevron is-reserved"></svg>';
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
  expect(timing(100)).toEqual({ ms: MOTION_SETTLE_MS, easing: "cubic-bezier(0.236, 0.708, 0.46, 0.854)" });
  expect(timing(274)).toEqual({ ms: MOTION_SETTLE_MS, easing: "cubic-bezier(0.328, 0.354, 0.655, 0.677)" });
  expect(timing(800)).toEqual({ ms: MOTION_SETTLE_MS, easing: "cubic-bezier(0.333, 0.333, 0.667, 0.667)" });
  expect(timing(2000)).toEqual({ ms: MOTION_SETTLE_MS, easing: "cubic-bezier(0.333, 0.333, 0.667, 0.667)" });
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

test("a copy of a row that went draws only outside the rows that come over it", async () => {
  // agent-pane-stream-row-overlap: the copy of a folded call ("Checked git status") fading where it
  // was while the reply slid up over it drew its text under the reply's in the fold's first frames.
  const { coverClip } = await import("./turnFold");
  const row = (from: number, to: number, height: number) => ({ from, to, height, padTop: 0, padBottom: 8 });
  // The copy at 100..132 (text to 124); the reply starts under it at 140 and slides up to 60.
  const copy = { from: 100, to: 100, height: 32, padTop: 0, padBottom: 8 };
  const reply = row(140, 60, 120);
  const clip = coverClip(copy, [reply], 0)!;
  // First frame: nothing of the reply is over the copy (it starts 8 px under its box). Last frame:
  // the reply's top is at 60, so all of the copy's 32 px is hidden from the bottom up.
  expect(clip[0].clipPath).toBe("inset(0px -4096px 0px -4096px)");
  expect(clip[1].clipPath).toBe("inset(0px -4096px 72px -4096px)");
  // At every frame between (both move linearly on one clock, and so does the clip) the copy's drawn
  // text stays over the reply's top.
  for (let step = 0; step <= 10; step += 1) {
    const p = step / 10;
    const replyTop = reply.from + (reply.to - reply.from) * p;
    const shownBottom = Math.min(copy.from + copy.height - copy.padBottom, copy.from + copy.height - 72 * p);
    if (shownBottom > copy.from) expect(shownBottom).toBeLessThanOrEqual(replyTop + 1e-9);
  }
  // A row that stays clear of the copy hides nothing of it.
  expect(coverClip(copy, [row(0, 0, 40), row(200, 180, 40)], 0)).toBeUndefined();
  // A row sliding up under the copy clips its bottom; the copy's own clip is kept.
  const under = coverClip(copy, [row(140, 110, 40)], 4)!;
  expect(under[0].clipPath).toBe("inset(0px -4096px 4px -4096px)");
  expect(under[1].clipPath).toBe("inset(0px -4096px 22px -4096px)");
  // A row over the copy that starts clipped at the copy's top (the reply over the live line when a
  // lagging turn ends) draws nothing over it at first, and the fold moves the copy down to that row's
  // bottom at rest (turnEndFold.ts `covers`): the copy keeps every line on every frame.
  const above = { from: 20, to: 0, height: 120, padTop: 0, padBottom: 8, clip: 40 };
  expect(coverClip({ ...copy, to: 120 }, [above], 0)).toBeUndefined();
});

test("a wipe's edge runs over the changed rows only, never pausing on the rows between", async () => {
  // cmux#50299: run from the top of the changed rows to their bottom, the edge crossed the unchanged
  // rows between them, and the view stood still for frames between two motions (78 seeds of 500).
  const { wipeSpans, wipeEdge, wipeReach } = await import("./turnEndFold");
  const spans = wipeSpans(
    [
      { top: 300, height: 40 },
      { top: 100, height: 50 },
      { top: 154, height: 20 },
    ],
    0,
    320,
  );
  // Rows a few px apart are one stretch; the one past the view's bottom is clamped to it.
  expect(spans).toEqual([
    { from: 100, to: 174 },
    { from: 300, to: 320 },
  ]);
  // Equal steps of the edge's run move it by equal lengths of changed rows: it jumps the gap.
  expect(wipeEdge(spans, 0)).toBe(100);
  expect(wipeEdge(spans, 74 / 94)).toBeCloseTo(174);
  expect(wipeEdge(spans, 80 / 94)).toBeCloseTo(306);
  expect(wipeEdge(spans, 1)).toBe(320);
  // Run up, it starts at the bottom.
  expect(wipeEdge(spans, 0, true)).toBe(320);
  for (const along of [0, 0.2, 0.5, 0.79, 0.9, 1]) {
    expect(wipeReach(spans, wipeEdge(spans, along))).toBeCloseTo(along);
    expect(wipeReach(spans, wipeEdge(spans, along, true), true)).toBeCloseTo(along);
  }
  // Nothing changed in the view: one pixel's span, never an empty run.
  expect(wipeSpans([{ top: 400, height: 30 }], 0, 320)).toEqual([{ from: 320, to: 321 }]);
});

/// A thread of absolutely placed rows in a DOM with layout read from their styles, and the keyframes
/// each element was last given.
async function foldDom() {
  const { JSDOM } = await import("jsdom");
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
  const frames = new Map<HTMLElement, Keyframe[][]>();
  proto.animate = function (keyframes) {
    frames.set(this, [...(frames.get(this) ?? []), keyframes as Keyframe[]]);
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
  return { dom, thread, frames, draw };
}

test("a turn that ends on a tool call keeps its work's copy in sight while the fold runs", async () => {
  // #49624 F1: the ended turn's footer comes in where its live line was. Read as the next turn's
  // first row, it took the copies of the work with it on the fold's first frame, and the view stood
  // blank for 108 ms (the fold matrix's `ends-on-tool` cell). A turn ending on its calls must never
  // show a blank view.
  const { captureTurnEnd, playTurnEnd, settleTurnEnd } = await import("./turnEndFold");
  const { dom, thread, frames, draw } = await foldDom();
  // The running header (turns.ts `turnHeaderId`: one row, two phases), its chevron held unseen.
  draw("worked-u", "worked", 0, 34).innerHTML = '<svg class="cv-worked__chevron is-reserved"></svg>';
  draw("work", "activity", 34, 60);
  draw(LIVE_THINKING, "thinking", 94, 22);
  const capture = captureTurnEnd(
    thread,
    thread,
    [row("worked-u", "worked"), row("summary-turn-1", "turnSummary")],
    "chat",
  )!;
  const work = capture.rows.find((entry) => entry.id === "work")!.copy!;
  thread.replaceChildren();
  draw("worked-u", "worked", 0, 34);
  draw("summary-turn-1", "turnSummary", 34, 32);
  const fold = playTurnEnd(thread, capture, "chat")!;
  try {
    // The work's copy is drawn, and it fades over the fold's clock: it is not dropped at once.
    expect(thread.contains(work)).toBe(true);
    const fades = frames.get(work)?.find((keyframes) => keyframes.some((frame) => frame.opacity !== undefined));
    expect(fades?.[0]!.opacity).toBe(1);
    expect(fades?.at(-1)!.opacity).toBe(0);
  } finally {
    settleTurnEnd(thread, fold);
    dom.window.close();
  }
  // The next turn's own rows coming in there do take that place: the copies under them go.
  const next = await foldDom();
  // The running header (turns.ts `turnHeaderId`: one row, two phases), its chevron held unseen.
  next.draw("worked-u", "worked", 0, 34).innerHTML = '<svg class="cv-worked__chevron is-reserved"></svg>';
  next.draw("work", "activity", 34, 60);
  next.draw(LIVE_THINKING, "thinking", 94, 22);
  const before = captureTurnEnd(next.thread, next.thread, [row("worked-u", "worked"), row("u2", "user")], "chat")!;
  const gone = before.rows.find((entry) => entry.id === "work")!.copy!;
  next.thread.replaceChildren();
  next.draw("worked-u", "worked", 0, 34);
  next.draw("u2", "user", 34, 40);
  const played = playTurnEnd(next.thread, before, "chat")!;
  try {
    expect(next.thread.contains(gone)).toBe(false);
  } finally {
    settleTurnEnd(next.thread, played);
    next.dom.window.close();
  }
});

test("a reply the swap grew opens to its full height on the fold's clock", async () => {
  // cmux#50299: the reply's last lines show in the render that ends the turn. Grown at once, they
  // drew a frame of motion of their own before the fold's; clipped to the height it drew, the reply
  // opens with the fold, one motion.
  const { captureTurnEnd, playTurnEnd, settleTurnEnd } = await import("./turnEndFold");
  const { dom, thread, frames, draw } = await foldDom();
  // The running header (turns.ts `turnHeaderId`: one row, two phases), its chevron held unseen.
  draw("worked-u", "worked", 0, 34).innerHTML = '<svg class="cv-worked__chevron is-reserved"></svg>';
  draw("work", "activity", 34, 60);
  draw("answer", "assistant", 94, 46);
  draw(LIVE_THINKING, "thinking", 140, 22);
  const capture = captureTurnEnd(
    thread,
    thread,
    [row("worked-u", "worked"), row("answer"), row("summary-turn-1", "turnSummary")],
    "chat",
  )!;
  thread.replaceChildren();
  draw("worked-u", "worked", 0, 34);
  const answer = draw("answer", "assistant", 34, 92);
  // The footer takes the live line's place, so the line's copy goes: nothing under the reply clips it.
  draw("summary-turn-1", "turnSummary", 126, 32);
  const fold = playTurnEnd(thread, capture, "chat")!;
  try {
    const clip = frames.get(answer)?.find((keyframes) => keyframes[0]!.clipPath !== undefined);
    expect(clip?.[0]!.clipPath).toBe("inset(-4096px -4096px 46px -4096px)");
    expect(clip?.at(-1)!.clipPath).toBe("inset(-4096px -4096px 0px -4096px)");
  } finally {
    settleTurnEnd(thread, fold);
    dom.window.close();
  }
});

test("drawsCopy: rows are a copy until acpmux's attach answers", () => {
  expect(drawsCopy({ connection: "connecting" })).toBe(true);
  expect(drawsCopy({ connection: "connected", drewKeptTail: true })).toBe(true);
  expect(drawsCopy({ connection: "connected", drewKeptTail: true, chatAttached: true })).toBe(false);
  expect(drawsCopy({ connection: "connected" })).toBe(false);
});
