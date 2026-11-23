// Exit before move (design/chat-fold-motion.md, exitLead.ts): every fold that takes text away has it
// gone before anything moves. Leo, 2026-11-21: "i rather dislike the folding right now bc the text is
// still visible as it gets folded/"collapsed" ... that text hiding as it travels so it doesnt show
// weird overlays is the big one ... we must hide text faster and sooner".
//
// Each case records the animations a fold starts and reads them as a timeline: the latest moment any
// leaving text still has ink must be no later than the first moment anything moves.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { EXIT_LEAD_MS, exitLeadMs, exitThenClose } from "../src/agent-session/acpmux/conversation/exitLead";
import { captureTurnEnd, playTurnEnd, settleTurnEnd } from "../src/agent-session/acpmux/conversation/turnEndFold";
import {
  playTurnFold,
  settleTurnFold,
  startTurnFold,
  type PlacedRows,
} from "../src/agent-session/acpmux/conversation/turnFold";
import { LIVE_THINKING } from "../src/agent-session/acpmux/conversation/turns";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

type Played = {
  node: HTMLElement;
  keyframes: Keyframe[];
  delay: number;
  duration: number;
};

const moves = (keyframes: Keyframe[]) =>
  keyframes.some(
    (frame) => frame.translate !== undefined || frame.height !== undefined || frame.clipPath !== undefined,
  ) &&
  new Set(keyframes.map((frame) => `${frame.translate ?? ""}|${frame.height ?? ""}|${frame.clipPath ?? ""}`)).size > 1;
const fades = (keyframes: Keyframe[]) => keyframes.at(-1)?.opacity === 0 && Number(keyframes[0]?.opacity ?? 1) > 0;

/// A page whose rows are laid out by their inline top and height, recording every animation.
function page() {
  const dom = new JSDOM("<!doctype html><main></main>", {
    pretendToBeVisual: true,
  });
  const thread = dom.window.document.querySelector<HTMLElement>("main")!;
  // The thread stands in for the scroller here, so it needs a view of its own: `captureTurnEnd`
  // plays nothing whose rows all sit outside the scroller's box, and jsdom gives every box its
  // inline `top`/`height`, which a bare <main> leaves at zero (a view of no height sees nothing).
  thread.style.height = "600px";
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
    const top = this.offsetTop;
    const height = this.offsetHeight;
    return {
      top,
      bottom: top + height,
      height,
      left: 0,
      right: 100,
      width: 100,
      x: 0,
      y: top,
      toJSON() {},
    };
  };
  const played: Played[] = [];
  proto.animate = function (keyframes, options) {
    const timing = (typeof options === "number" ? { duration: options } : (options ?? {})) as KeyframeAnimationOptions;
    played.push({
      node: this,
      keyframes: keyframes as Keyframe[],
      delay: Number(timing.delay ?? 0),
      duration: Number(timing.duration ?? 0),
    });
    return {
      cancel() {},
      finish() {},
      onfinish: null,
      oncancel: null,
    } as unknown as Animation;
  };
  const draw = (id: string, kind: string, top: number, height: number, index?: number) => {
    const node = dom.window.document.createElement("article");
    node.className = `acpmux-row acpmux-${kind}`;
    node.dataset.rowId = id;
    if (index !== undefined) node.setAttribute("aria-posinset", String(index + 1));
    node.style.top = `${top}px`;
    node.style.height = `${height}px`;
    node.textContent = `${kind} ${id}`;
    thread.append(node);
    return node;
  };
  return { dom, thread, played, draw };
}

/// The last moment a leaving copy's text has ink, and the first moment anything moves (ms from the start).
function timeline(played: Played[], leaving: (node: HTMLElement) => boolean) {
  const exits = played.filter((entry) => leaving(entry.node) && fades(entry.keyframes));
  const moving = played.filter((entry) => moves(entry.keyframes));
  return {
    exits: exits.length,
    inkUntil: Math.max(0, ...exits.map((entry) => entry.delay + entry.duration)),
    movesFrom: Math.min(...moving.map((entry) => entry.delay)),
    moving: moving.length,
    // No move carries a leaving copy's opacity on its own clock.
    fadingWhileMoving: played.filter(
      (entry) => leaving(entry.node) && moves(entry.keyframes) && entry.keyframes.some((f) => f.opacity !== undefined),
    ).length,
  };
}

const row = (id: string, kind: AcpmuxRow["kind"] = "assistant"): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind,
});

test("the exit lead is half the quick step, never past a third of the fold, and shorter for faint text", () => {
  expect(EXIT_LEAD_MS).toBe(40);
  expect(exitLeadMs(180)).toBe(40);
  expect(exitLeadMs(90)).toBe(30);
  expect(exitLeadMs(180, 0.5)).toBe(20);
  expect(exitLeadMs(0)).toBe(0);
  expect(exitLeadMs(180, 0)).toBe(0);
});

test("a body that closes: its ink is gone while its height holds, then the height shuts", () => {
  const frames = exitThenClose({ height: 120, opacity: 1 }, { height: 0 }, 40, 180, "ease");
  expect(frames).toHaveLength(3);
  expect(frames[1]).toMatchObject({ height: "120px", opacity: 0 });
  expect(frames[1]!.offset).toBeCloseTo(40 / 220, 9);
  expect(frames[2]).toEqual({ height: "0px", opacity: 0 });
});

test("a turn's end: each removed row's copy is gone before any row, copy or clip moves", () => {
  const { dom, thread, played, draw } = page();
  draw("working-u", "working", 0, 34);
  draw("work", "activity", 34, 60);
  draw("answer", "assistant", 94, 50);
  draw(LIVE_THINKING, "thinking", 144, 22);
  const capture = captureTurnEnd(thread, thread, [row("worked-u", "worked"), row("answer")], "chat")!;
  const copies = new Set(capture.rows.flatMap((entry) => (entry.copy ? [entry.copy] : [])));
  expect(copies.size).toBeGreaterThan(0);
  thread.replaceChildren();
  draw("worked-u", "worked", 100, 34);
  draw("answer", "assistant", 134, 50);
  const fold = playTurnEnd(thread, capture, "chat")!;
  try {
    const seen = timeline(played, (node) => copies.has(node));
    expect(seen.exits).toBe(copies.size);
    expect(seen.moving).toBeGreaterThan(0);
    expect(seen.fadingWhileMoving).toBe(0);
    expect(seen.inkUntil).toBeLessThanOrEqual(seen.movesFrom + 1e-6);
    expect(seen.inkUntil).toBeLessThanOrEqual(EXIT_LEAD_MS);
  } finally {
    settleTurnEnd(thread, fold);
    dom.window.close();
  }
});

test("a reader closing Worked for: each hidden row's copy is gone before the rows under it slide up", () => {
  const { dom, thread, played, draw } = page();
  const placed = (ids: string[], heights: number[]): PlacedRows => {
    const tops: number[] = [];
    heights.reduce((top, height) => (tops.push(top), top + height), 0);
    return { count: ids.length, idAt: (index) => ids[index], tops };
  };
  draw("worked-u", "worked", 0, 30, 0);
  const hidden = [draw("call-1", "activity", 30, 40, 1), draw("call-2", "activity", 70, 40, 2)];
  draw("answer", "assistant", 110, 50, 3);
  const before = placed(["worked-u", "call-1", "call-2", "answer"], [30, 40, 40, 50]);
  const ghosts = new Set<HTMLElement>();
  const fold = startTurnFold(thread, "worked-u", false, before, "chat", 0)!;
  expect(fold).toBeDefined();
  try {
    // The close renders: the calls leave, the answer is placed under the line.
    playTurnFold(fold, thread, before, "chat", ghosts, 0);
    for (const node of hidden) node.remove();
    const answer = thread.querySelector<HTMLElement>('[data-row-id="answer"]')!;
    answer.setAttribute("aria-posinset", "2");
    answer.style.top = "30px";
    expect(playTurnFold(fold, thread, placed(["worked-u", "answer"], [30, 50]), "chat", ghosts, 0)).toBe(true);
    expect(ghosts.size).toBe(2);
    const seen = timeline(played, (node) => ghosts.has(node));
    expect(seen.exits).toBe(2);
    expect(seen.moving).toBeGreaterThan(0);
    expect(seen.fadingWhileMoving).toBe(0);
    expect(seen.inkUntil).toBeLessThanOrEqual(seen.movesFrom + 1e-6);
  } finally {
    settleTurnFold(thread, fold, ghosts);
    dom.window.close();
  }
});

test("a reader opening Worked for plays no lead: the rows move at once", () => {
  const { dom, thread, played, draw } = page();
  draw("worked-u", "worked", 0, 30, 0);
  draw("answer", "assistant", 30, 50, 1);
  const before: PlacedRows = {
    count: 2,
    idAt: (index) => ["worked-u", "answer"][index],
    tops: [0, 30],
  };
  const ghosts = new Set<HTMLElement>();
  const fold = startTurnFold(thread, "worked-u", true, before, "chat", 0)!;
  try {
    expect(fold.lead).toBe(0);
    const answer = thread.querySelector<HTMLElement>('[data-row-id="answer"]')!;
    answer.setAttribute("aria-posinset", "3");
    answer.style.top = "70px";
    draw("call-1", "activity", 30, 40, 1);
    playTurnFold(
      fold,
      thread,
      {
        count: 3,
        idAt: (index) => ["worked-u", "call-1", "answer"][index],
        tops: [0, 30, 70],
      },
      "chat",
      ghosts,
      0,
    );
    const slid = played.filter((entry) => moves(entry.keyframes));
    expect(slid.length).toBeGreaterThan(0);
    for (const entry of slid) expect(entry.delay).toBeLessThanOrEqual(0);
  } finally {
    settleTurnFold(thread, fold, ghosts);
    dom.window.close();
  }
});

test("the since line moves no row: it fades and narrows on the compositor, never animating size", () => {
  const css = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/conversation/unread.css"), "utf8");
  const motion = css.slice(css.indexOf("@media (prefers-reduced-motion: no-preference)"));
  expect(motion).toMatch(
    /\.cv-since__line,\s*\.cv-since__rule \{\s*transition:\s*opacity var\(--agent-motion-calm\) var\(--agent-ease-out\),\s*scale var\(--agent-motion-calm\) var\(--agent-ease-out\);/,
  );
  const since = css.slice(css.indexOf(".cv-since {"), css.indexOf(".acpmux-over-top"));
  expect(since).not.toMatch(/transition:[^;]*\b(?:height|margin|padding|block-size)\b/);
  expect(since).toMatch(/\.cv-since__menu \{\s*position: absolute;/);
});
test("the gallery's arms: none plays no lead, quick a whole quick step, shipped the 40 ms lead", () => {
  const { document } = new JSDOM(
    "<!doctype html><div data-exit-lead=none><p id=a></p></div><div data-exit-lead=quick><p id=b></p></div><p id=c></p>",
  ).window;
  expect(exitLeadMs(180, 1, document.getElementById("a"))).toBe(0);
  expect(exitLeadMs(180, 1, document.getElementById("b"))).toBe(80);
  expect(exitLeadMs(180, 1, document.getElementById("c"))).toBe(40);
});
