import { expect, test } from "bun:test";
import { Window } from "happy-dom";
import { judgeStep } from "../src/gallery/play";
import {
  REST_FRAMES,
  bottomFoldOf,
  isExpansionShift,
  sampleBoxes,
  scoreBoxFrames,
  type BoxFrame,
  type BoxSample,
} from "../src/gallery/shift";

const viewport = { width: 800, height: 600 };
const row = (y: number, extra: Partial<BoxSample> = {}): BoxSample => ({
  box: { x: 0, y, width: 800, height: 40 },
  label: "div.cv-row",
  ...extra,
});
const frames = (...list: [number, BoxSample][][]): BoxFrame[] => list.map((entries) => new Map(entries));
/** A box that has held still long enough for its moves to count. */
const rested = (id: number, y: number, extra: Partial<BoxSample> = {}) =>
  Array.from({ length: REST_FRAMES + 1 }, () => [[id, row(y, extra)]] as [number, BoxSample][]);

test("a still page scores zero", () => {
  expect(scoreBoxFrames(frames(...rested(1, 100), [[1, row(100)]]), viewport).score).toBe(0);
});

test("a rested row that jumps scores like CLS: its share of the viewport times the move's share", () => {
  const shift = scoreBoxFrames(frames(...rested(1, 100), [[1, row(130)]]), viewport);
  // The union of before and after is 800 x 70 of 800 x 600; the move is 30 of 800.
  expect(shift.score).toBeCloseTo(((800 * 70) / (800 * 600)) * (30 / 800), 5);
  expect(shift.moves).toEqual([{ label: "div.cv-row", frame: REST_FRAMES + 1, dx: 0, dy: 30 }]);
});

test("a row still entering (not yet rested) does not count, a step's first frame has rested", () => {
  expect(scoreBoxFrames(frames([[1, row(104)]], [[1, row(100)]], [[1, row(100)]]), viewport).score).toBe(0);
  expect(
    scoreBoxFrames(frames([[1, row(104)]], [[1, row(100)]]), viewport, { restedAtStart: true }).score,
  ).toBeGreaterThan(0);
});

test("moves a scroller made count (the browser's CLS subtracts them): a bottom-pinned transcript scrolling up", () => {
  const shift = scoreBoxFrames(frames(...rested(1, 400), [[1, row(250)]]), viewport, { restedAtStart: true });
  expect(shift.score).toBeGreaterThan(0.01);
});

test("the target, and rows after it pushed straight down, are exempt; rows before it are not", () => {
  const target = { targeted: true };
  const after = { after: true };
  expect(scoreBoxFrames(frames(...rested(1, 100, target), [[1, row(140, target)]]), viewport).score).toBe(0);
  expect(scoreBoxFrames(frames(...rested(2, 300, after), [[2, row(380, after)]]), viewport).score).toBe(0);
  // Pushed up, or sideways, is still a shift.
  expect(scoreBoxFrames(frames(...rested(2, 300, after), [[2, row(220, after)]]), viewport).score).toBeGreaterThan(0);
  expect(scoreBoxFrames(frames(...rested(3, 50), [[3, row(10)]]), viewport).score).toBeGreaterThan(0);
});

test("rows before a line opening at the transcript's very bottom may rise straight up, not drop or slide", () => {
  const before = { before: true };
  expect(scoreBoxFrames(frames(...rested(1, 100, before), [[1, row(93, before)]]), viewport).score).toBe(0);
  expect(scoreBoxFrames(frames(...rested(1, 100, before), [[1, row(110, before)]]), viewport).score).toBeGreaterThan(0);
  const sideways = { ...row(93, before), box: { x: 8, y: 93, width: 800, height: 40 } };
  expect(scoreBoxFrames(frames(...rested(1, 100, before), [[1, sideways]]), viewport).score).toBeGreaterThan(0);
});

test("rows inside a row opening at the very bottom move with it, as its toggle does", () => {
  // "Received N messages" at the transcript's end: its batch row opens and the rows it holds rise
  // with the text above. They are the opening row's own body, never a shift of their own.
  const window = new Window({ width: 800, height: 600 });
  const doc = window.document as unknown as Document;
  doc.body.innerHTML = `
    <div data-row-id="above">above</div>
    <div data-row-id="batch" data-bottom-stack-fold>
      <button class="toggle">Received 3 messages</button>
      <div data-row-id="inner">a message</div>
    </div>`;
  const box = { x: 0, y: 100, width: 800, height: 40, top: 100, left: 0, right: 800, bottom: 140 };
  for (const element of doc.querySelectorAll("[data-row-id]"))
    (element as HTMLElement).getBoundingClientRect = () => ({ ...box, toJSON: () => box }) as DOMRect;
  const frame = sampleBoxes(doc, doc.querySelector(".toggle"));
  const byLabel = (id: string) => [...frame.values()].find((sample) => sample.label.includes(`[row ${id}]`))!;
  expect(byLabel("inner").targeted).toBe(true);
  expect(byLabel("batch").targeted).toBe(true);
  expect(byLabel("above")).toMatchObject({ targeted: false, before: true });
  // Away from the bottom, only the target's own line is exempt.
  doc.querySelector("[data-bottom-stack-fold]")!.removeAttribute("data-bottom-stack-fold");
  const plain = sampleBoxes(doc, doc.querySelector(".toggle"));
  expect([...plain.values()].find((sample) => sample.label.includes("[row inner]"))!.targeted).toBe(false);
  window.close();
});

test("a browser layout shift that is the step's own expansion does not count; any other move does", () => {
  // The browser's CLS knows no target: a fold's rows below sliding down with it read as a shift, and
  // only the frames inside the step's settle window counted, so a fold that moves more of its height
  // early scored more though every row went to the same place.
  const window = new Window({ width: 800, height: 600 });
  const doc = window.document as unknown as Document;
  doc.body.innerHTML = `
    <div class="above">above</div>
    <section class="row"><button class="toggle">Read 3 files</button><div class="body">body</div></section>
    <div class="below">below<span class="band">Working</span></div>
    <div class="acpmux-transcript-after-latest"><button class="tray">2 running</button></div>`;
  const $ = (selector: string) => doc.querySelector(selector)!;
  const rect = (y: number, height = 40, x = 0) => ({ x, y, width: 800, height });
  const moved = (selector: string, from: number, to: number, x = 0) => ({
    node: $(selector),
    previousRect: rect(from),
    currentRect: rect(to, 40, x),
  });
  const toggle = $(".toggle");
  // Rows after the toggle pushed straight down, and the toggle's own row growing, are its expansion.
  expect(isExpansionShift([moved(".below", 200, 252), moved(".row", 100, 100)], toggle)).toBe(true);
  // A band that was clipped to nothing and came into view goes with the row it sits in.
  expect(
    isExpansionShift(
      [moved(".below", 200, 252), { node: $(".band"), previousRect: rect(0, 0), currentRect: rect(252) }],
      toggle,
    ),
  ).toBe(true);
  // A row after it pushed out past the view's bottom: the browser clips its new rect to nothing, so
  // where its box is now says it went straight down (the live line under a digest opening whole).
  const below = $(".below") as unknown as { getBoundingClientRect: () => DOMRect };
  const out = { node: $(".below"), previousRect: rect(560), currentRect: { x: 0, y: 0, width: 0, height: 0 } };
  below.getBoundingClientRect = () => rect(774) as DOMRect;
  expect(isExpansionShift([out], toggle)).toBe(true);
  // Gone out of view any other way (up, or sideways) is still a shift, and a row before it is too.
  below.getBoundingClientRect = () => rect(-60) as DOMRect;
  expect(isExpansionShift([out], toggle)).toBe(false);
  below.getBoundingClientRect = () => rect(774, 40, 6) as DOMRect;
  expect(isExpansionShift([out], toggle)).toBe(false);
  expect(isExpansionShift([{ ...out, node: $(".above") }], toggle)).toBe(false);
  // A row after it pushed up or sideways, or a row before it moving, is still a shift.
  expect(isExpansionShift([moved(".below", 200, 180)], toggle)).toBe(false);
  expect(isExpansionShift([moved(".below", 200, 252, 6)], toggle)).toBe(false);
  expect(isExpansionShift([moved(".below", 200, 252), moved(".above", 50, 30)], toggle)).toBe(false);
  // No target (a wait step) or no sources: nothing is exempt.
  expect(isExpansionShift([moved(".below", 200, 252)], null)).toBe(false);
  expect(isExpansionShift([], toggle)).toBe(false);
  // The after-latest tray is the transcript's end: opening it at the end lifts the text above.
  expect(isExpansionShift([moved(".above", 50, 2)], $(".tray"))).toBe(true);
  expect(isExpansionShift([moved(".above", 50, 90)], $(".tray"))).toBe(false);
  window.close();
});

test("toggles the play clicked itself are the next step's targets too: their pushes are theirs", () => {
  // A play that opens four lines with plain clicks, then waits: the wait has no target of its own.
  const window = new Window({ width: 800, height: 600 });
  const doc = window.document as unknown as Document;
  doc.body.innerHTML = `
    <div data-row-id="one"><button class="a">one</button></div>
    <div data-row-id="two"><button class="b">two</button></div>
    <div data-row-id="three">three</div>`;
  const box = { x: 0, y: 100, width: 800, height: 40, top: 100, left: 0, right: 800, bottom: 140 };
  for (const element of doc.querySelectorAll("[data-row-id]"))
    (element as HTMLElement).getBoundingClientRect = () => ({ ...box, toJSON: () => box }) as DOMRect;
  const $ = (selector: string) => doc.querySelector(selector)!;
  const frame = sampleBoxes(doc, [$(".a"), $(".b")]);
  const byLabel = (id: string) => [...frame.values()].find((sample) => sample.label.includes(`[row ${id}]`))!;
  expect(byLabel("one").targeted).toBe(true);
  expect(byLabel("two").targeted).toBe(true);
  expect(byLabel("three")).toMatchObject({ targeted: false, after: true });
  const rect = (y: number) => ({ x: 0, y, width: 800, height: 40 });
  const down = { node: $("[data-row-id=three]"), previousRect: rect(200), currentRect: rect(240) };
  expect(isExpansionShift([down], [$(".a"), $(".b")])).toBe(true);
  // With no step target and nothing clicked, a wait's moves all count.
  expect(isExpansionShift([down], [])).toBe(false);
  expect([...sampleBoxes(doc, []).values()].every((sample) => !sample.targeted && !sample.after)).toBe(true);
  window.close();
});

test("the running tray over the composer is a fold at the bottom only over the running turn's live line", () => {
  // VirtualTranscript `trayBase`: what the tray opens moves no row, save over the live line, where
  // the rows rise with it for the rest of the line's rest gap.
  const window = new Window({ width: 800, height: 600 });
  const doc = window.document as unknown as Document;
  doc.body.innerHTML = `
    <article class="acpmux-row" data-row-id="reply">reply</article>
    <article class="acpmux-row acpmux-row--below" data-row-id="line">Thinking</article>
    <div class="acpmux-dock"><section class="acpmux-running-tray"><button class="head">2 running</button></section></div>`;
  const head = doc.querySelector(".head")!;
  expect(bottomFoldOf(head)).toBe(doc.querySelector(".acpmux-running-tray"));
  const rect = (y: number) => ({ x: 0, y, width: 800, height: 40 });
  const rise = { node: doc.querySelector("[data-row-id=reply]"), previousRect: rect(100), currentRect: rect(80) };
  expect(isExpansionShift([rise], head)).toBe(true);
  // With any other last row, a row that rises when the tray opens is a shift.
  doc.querySelector("[data-row-id=line]")!.classList.remove("acpmux-row--below");
  expect(bottomFoldOf(head)).toBeNull();
  expect(isExpansionShift([rise], head)).toBe(false);
  window.close();
});

test("a resize lets each box move once; a second move is a bounce", () => {
  const once = frames(...rested(1, 100), [[1, row(120)]], [[1, row(120)]]);
  expect(scoreBoxFrames(once, viewport, { firstMoveFree: true }).score).toBe(0);
  const bounce = frames(...rested(1, 100), [[1, row(120)]], [[1, row(100)]]);
  expect(scoreBoxFrames(bounce, viewport, { firstMoveFree: true }).score).toBeGreaterThan(0);
});

test("half-pixel rounding and boxes outside the viewport are not shift", () => {
  expect(scoreBoxFrames(frames(...rested(1, 100), [[1, row(100.4)]]), viewport).score).toBe(0);
  expect(scoreBoxFrames(frames(...rested(1, 700), [[1, row(760)]]), viewport).score).toBe(0);
});

// A wait is the page loading what it waits for (a header button arriving, a mention list opening):
// the play does not fail on it. Gallery health scores it against the state's shift baseline.
test("a wait step's shift and anchor moves do not fail the play; an action step's do", () => {
  const measured = {
    step: "s",
    settleMs: 10,
    anchorMoves: [{ anchor: "a", before: null, after: null, delta: 40 }],
    layoutShift: 0.01,
    shifts: [],
    boxShift: 0.01,
    boxMoves: [{ label: "div.ui-popup", frame: 3, dx: 0, dy: -32 }],
    longFrames: [],
    frameSource: "raf" as const,
  };
  expect(judgeStep({ ...measured, action: "wait" }).status).toBe("pass");
  expect(judgeStep({ ...measured, action: "click" }).status).toBe("fail");
});
