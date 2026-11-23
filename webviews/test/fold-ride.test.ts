import { afterEach, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { markHeightFold } from "../src/agent-session/acpmux/conversation/fold";
import { FoldRide } from "../src/agent-session/acpmux/conversation/foldRide";

// Two folds playing at once in different rows: the lower folding row rides the upper fold's change
// too, or its body overlaps (or leaves a gap under) the row above until the fold ends (review of
// #39917: "a lower row retaining 40px when it needed 90px").

let window: Window | undefined;
const globals = globalThis as { HTMLElement?: unknown };
const realHTMLElement = globals.HTMLElement;
afterEach(() => {
  window?.close();
  window = undefined;
  globals.HTMLElement = realHTMLElement;
});

function transcript(count: number) {
  window = new Window();
  globals.HTMLElement = window.HTMLElement;
  const document = window.document as unknown as Document;
  const scroller = document.createElement("div");
  scroller.className = "acpmux-scroll";
  document.body.append(scroller);
  const list = document.createElement("div");
  scroller.append(list);
  const rect = (top: number, bottom: number) => ({ top, bottom, height: bottom - top }) as DOMRect;
  scroller.getBoundingClientRect = () => rect(0, 600);
  const rows: HTMLElement[] = [];
  for (let index = 1; index <= count; index += 1) {
    const row = document.createElement("div");
    row.className = "acpmux-row";
    row.dataset.rowId = `row-${index}`;
    row.setAttribute("aria-posinset", String(index));
    row.setAttribute("aria-setsize", "100");
    // Each row 100px tall from the view's top; the last reaches far past the view's end.
    row.getBoundingClientRect = () => rect((index - 1) * 100, index === count ? 3000 : index * 100);
    list.append(row);
    rows.push(row);
  }
  return rows;
}

test("a folding row under another fold rides that fold's change as it grows", () => {
  const rows = transcript(4);
  const [upper, , lower, last] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  const placed = new Map<HTMLElement, number>(rows.map((row) => [row, 100]));
  const height = new Map(placed);
  const ride = new FoldRide({ placed: (row) => placed.get(row), height: (row) => height.get(row), finish: () => {} });
  markHeightFold(upper, 10_000);
  markHeightFold(lower, 10_000);

  height.set(upper, 140);
  expect(ride.ride([upper])).toBe(true);
  height.set(lower, 110);
  expect(ride.ride([lower])).toBe(true);
  // The upper fold keeps growing while the lower one holds still.
  height.set(upper, 190);
  expect(ride.ride([upper])).toBe(true);

  expect(lower.style.translate).toBe("0 90px");
  expect(last.style.translate).toBe("0 100px");
  expect(upper.style.translate).toBe("");
  ride.release();
  expect(lower.style.translate).toBe("");
  expect(last.style.translate).toBe("");
});

// The reader clicks a lower disclosure while an upper fold still plays: the transcript holds the
// clicked line by moving the offset, so the ride gives way rather than translate it away (review of
// #39917: "it drifts, then snaps back when placement resumes").
test("the ride gives way when it would move the line the reader clicked", () => {
  const rows = transcript(4);
  const [upper, , lower, last] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  const toggle = lower.ownerDocument.createElement("button");
  lower.append(toggle);
  const placed = new Map<HTMLElement, number>(rows.map((row) => [row, 100]));
  const height = new Map(placed);
  toggle.getBoundingClientRect = () => ({ top: 250, bottom: 270, height: 20 }) as DOMRect;
  let held: { toggle: HTMLElement; top: number } | undefined;
  const ride = new FoldRide({
    placed: (row) => placed.get(row),
    height: (row) => height.get(row),
    finish: () => {},
    held: () => held,
  });
  markHeightFold(upper, 10_000);
  height.set(upper, 140);
  expect(ride.ride([upper])).toBe(true);
  held = { toggle, top: 250 };
  height.set(upper, 160);
  expect(ride.ride([upper])).toBe(false);
  expect(last.style.translate).toBe("");
  // Its own fold, with nothing folding above it, still rides.
  markHeightFold(lower, 10_000);
  height.set(upper, 100);
  placed.set(upper, 100);
  height.set(lower, 130);
  const fresh = new FoldRide({
    placed: (row) => placed.get(row),
    height: (row) => height.get(row),
    finish: () => {},
    held: () => held,
  });
  expect(fresh.ride([lower])).toBe(true);
  expect(last.style.translate).toBe("0 30px");
  fresh.release();
});

// Two disclosures in one row (a group's Shell cards): the reader clicks the lower one while the upper
// one's body still grows. Its row does not shift, but the clicked line moves inside it, so the ride
// gives way and the transcript holds the line by the offset (review of #39917 at 466bcfb5).
test("the ride gives way when a fold above the clicked line in its own row moves it", () => {
  const rows = transcript(4);
  const [, , row, last] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  const toggle = row.ownerDocument.createElement("button");
  row.append(toggle);
  let toggleTop = 250;
  toggle.getBoundingClientRect = () => ({ top: toggleTop, bottom: toggleTop + 20, height: 20 }) as DOMRect;
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  const height = new Map(placed);
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    finish: () => {},
    held: () => ({ toggle, top: 250 }),
  });
  markHeightFold(row, 10_000);
  height.set(row, 140);
  expect(ride.ride([row])).toBe(true);
  expect(last.style.translate).toBe("0 40px");
  // The upper card's body grows above the clicked line: it moves down 30px.
  toggleTop = 280;
  height.set(row, 180);
  expect(ride.ride([row])).toBe(false);
  expect(last.style.translate).toBe("");
});

// A fold reversed mid-way lands its row back at the height the transcript placed it at: the
// transcript has nothing to place, and the rows under it must not keep the translate of a change
// undone (review of #39917 at ff692235: "100 -> 140 -> 120 -> 100 leaving a stale 20px").
test("a fold back at its placed height leaves the rows under it no translate", () => {
  const rows = transcript(4);
  const [row, , , last] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  const height = new Map(placed);
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    finish: () => {},
  });
  markHeightFold(row, 10_000);
  height.set(row, 140);
  expect(ride.ride([row])).toBe(true);
  height.set(row, 120);
  expect(ride.ride([row])).toBe(true);
  expect(last.style.translate).toBe("0 20px");
  height.set(row, 100);
  ride.settled([row], true);
  expect(last.style.translate).toBe("");
  // Where rows may not ride (the view follows the latest row), the ride lets go.
  height.set(row, 130);
  expect(ride.ride([row])).toBe(true);
  height.set(row, 100);
  ride.settled([row], false);
  expect(ride.riding).toBe(false);
  expect(last.style.translate).toBe("");
});

// A margin drag's selection keeps a row far below mounted, outside the run: the rows between are
// not mounted, so its reach says nothing of what a close would show, and the ride gives way.
test("the ride gives way when the mounted rows are not one run", () => {
  const rows = transcript(4);
  const [row, , , held] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  held.setAttribute("aria-posinset", "40");
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  const height = new Map(placed);
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    finish: () => {},
  });
  markHeightFold(row, 10_000);
  height.set(row, 60);
  expect(ride.ride([row])).toBe(false);
  expect(held.style.translate).toBe("");
});

// A ride that lets go hands the transcript how far each row showed below its placed top, so the
// placement of its heights does not move those rows by it again. A placement before its heights land
// (a scroll's commit still on the old heights) neither uses nor spends it (review of #39917 at
// 16b52a67: "offset 2090 instead of 2290"); one with no placement after it hands over nothing.
test("a ride hands over its rows' shifts to the placement of its heights", () => {
  const rows = transcript(4);
  const [row, below] = rows as [HTMLElement, HTMLElement];
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  const height = new Map(placed);
  let drawn: object = {};
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    drawn: () => drawn,
    finish: () => {},
  });
  markHeightFold(row, 10_000);
  height.set(row, 140);
  expect(ride.ride([row])).toBe(true);
  const ids = rows.map((each) => ({ id: each.dataset.rowId! }));
  const before = drawn;
  ride.release();
  expect(below.style.translate).toBe("");
  // A placement still on the heights the ride let go on.
  expect(ride.handedFolds(ids, before)).toBeUndefined();
  ride.takeHanded(before);
  // The placement of its heights: the fold, at its row's index, wherever the rows moved to.
  drawn = {};
  expect(ride.handedFolds(ids, drawn)).toEqual([{ index: 0, delta: 40 }]);
  expect(ride.handedFolds([{ id: "older" }, ...ids], drawn)).toEqual([{ index: 1, delta: 40 }]);
  ride.takeHanded(drawn);
  expect(ride.handedFolds(ids, {})).toBeUndefined();
  expect(ride.ride([row])).toBe(true);
  height.set(row, 100);
  ride.settled([row], false);
  expect(ride.handedFolds(ids, {})).toBeUndefined();
});

// A chat switch lets go of the ride and of its hand-over: the new chat's first placement of new
// heights must not move a row whose id the old chat used by the old fold (review of #39917 at
// e2f830ca: "offset 1200 to 1160 after a 40 px fold in the previous chat").
test("a reset forgets the hand-over as well as the ride", () => {
  const rows = transcript(4);
  const [row, below] = rows as [HTMLElement, HTMLElement];
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  const height = new Map(placed);
  const drawn = {};
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    drawn: () => drawn,
    finish: () => {},
  });
  markHeightFold(row, 10_000);
  height.set(row, 140);
  expect(ride.ride([row])).toBe(true);
  ride.reset();
  expect(ride.riding).toBe(false);
  expect(below.style.translate).toBe("");
  expect(ride.handedFolds([{ id: row.dataset.rowId! }], {})).toBeUndefined();
});

// A row still playing its own animation (a live notice's entry) may hold its translate over the
// ride's, staying still while the rows around it move (review of #39917 at fde040fe): the ride gives
// way and the transcript places the rows while it plays.
test("the ride gives way when a row it would move plays its own animation", () => {
  const rows = transcript(4);
  const [row, , notice, last] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  let playing = true;
  notice.getAnimations = () => (playing ? [{ playState: "running" } as Animation] : []);
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  const height = new Map(placed);
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    finish: () => {},
  });
  markHeightFold(row, 10_000);
  height.set(row, 140);
  expect(ride.ride([row])).toBe(false);
  expect(last.style.translate).toBe("");
  playing = false;
  expect(ride.ride([row])).toBe(true);
  expect(notice.style.translate).toBe("0 40px");
  ride.release();
});

// A row may wear a translate that is not the ride's: the running turn's live line, held where it is
// drawn while the reader has the view (pinnedLiveLine.ts `hold`, with a clip on the row over it by the
// same distance). The ride wrote its own translate over that one and took it off at its end, so the
// line went to its layout place and the clip stayed: a blank band over "Thinking" (review of #41661).
// The ride gives way and leaves that translate as it is.
test("the ride gives way when a row it would move wears a translate that is not the ride's", () => {
  const rows = transcript(4);
  const [row, , under, live] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  const height = new Map(placed);
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    finish: () => {},
  });
  markHeightFold(row, 10_000);
  live.style.translate = "0 -30px";
  height.set(row, 140);
  expect(ride.ride([row])).toBe(false);
  expect(live.style.translate).toBe("0 -30px");
  expect(under.style.translate).toBe("");

  // The line let go: the rows ride, the live line with them.
  live.style.translate = "";
  expect(ride.ride([row])).toBe(true);
  expect(under.style.translate).toBe("0 40px");
  expect(live.style.translate).toBe("0 40px");

  // Held again while the rows ride (another owner wrote over the ride's translate): the ride gives
  // way and takes off its own translates only.
  live.style.translate = "0 -30px";
  height.set(row, 160);
  expect(ride.ride([row])).toBe(false);
  expect(live.style.translate).toBe("0 -30px");
  expect(under.style.translate).toBe("");
});

// A row glide the reader's scroll holds is paused (tailGlide.ts `hold`). A paused animation of a
// row's translate still wins over the inline one the ride writes, so that row stood still while the
// rows around it rode (review of #41661). A paused animation of anything else moves no row.
test("the ride gives way when a row it would move holds a paused animation of its translate", () => {
  const rows = transcript(4);
  const [row, , glided, last] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  const paused = (frame: Keyframe) =>
    ({ playState: "paused", effect: { getKeyframes: () => [frame, {}] } }) as unknown as Animation;
  let held = [paused({ translate: "0 12px" })];
  glided.getAnimations = () => held;
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  const height = new Map(placed);
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    finish: () => {},
  });
  markHeightFold(row, 10_000);
  height.set(row, 140);
  expect(ride.ride([row])).toBe(false);
  expect(glided.style.translate).toBe("");
  expect(last.style.translate).toBe("");
  held = [paused({ transform: "translateY(12px)" })];
  expect(ride.ride([row])).toBe(false);

  held = [paused({ opacity: 0 })];
  expect(ride.ride([row])).toBe(true);
  expect(glided.style.translate).toBe("0 40px");
  ride.release();
});

// Input while rows ride: the scroll range and layout are still the placed ones, so the transcript
// places every row now, before the input reaches anything (review of #39917 at 184fed21 and
// e357b4a0: a scroll to a run's foot 1250px short, a map drag 800px short). Nothing riding, input
// places nothing.
test("input lands the ride: the rows are placed before it reaches anything", () => {
  const rows = transcript(4);
  const [row, below] = rows as [HTMLElement, HTMLElement];
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  const height = new Map(placed);
  const finished: HTMLElement[][] = [];
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    finish: (folds) => finished.push(folds),
  });
  ride.land();
  expect(finished).toEqual([]);
  markHeightFold(row, 10_000);
  height.set(row, 900);
  expect(ride.ride([row])).toBe(true);
  expect(below.style.translate).toBe("0 800px");
  ride.land();
  expect(ride.riding).toBe(false);
  expect(below.style.translate).toBe("");
  expect(finished).toEqual([[row]]);
  // The fold plays on: the transcript places it to its end (a map scrub goes on aiming by the
  // layout), and the row's next fold rides again.
  height.set(row, 950);
  expect(ride.ride([row])).toBe(false);
  expect(below.style.translate).toBe("");
  markHeightFold(row, 20_000);
  expect(ride.ride([row])).toBe(true);
  expect(below.style.translate).toBe("0 850px");
  ride.release();
});

// A fold near the transcript's end, the view not at it: the last row stays under the view's end at
// every frame, so nothing of the end shows and the rows ride, as they do far from the end. The ride
// stood aside whenever the last row was within a screen of the view's end: closing "Show more" 1234px
// over the end of a 1000px view rode one frame, then placed every row on each later frame
// (chat-fold-frame-budget: 45 row renders for 21 mounted rows). It still gives way on the frame the
// last row would end over the view's end: from there the end shows, and the transcript places it.
test("a fold rides while the transcript's last row stays under the view's end", () => {
  const rows = transcript(4);
  const [row, , under, last] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  // The mounted rows are the transcript's last ones.
  for (const each of rows) each.setAttribute("aria-setsize", "4");
  const scroller = row.closest<HTMLElement>(".acpmux-scroll")!;
  Object.defineProperty(scroller, "clientHeight", { value: 600 });
  Object.defineProperty(scroller, "scrollHeight", { value: 5000 });
  // The last row ends 500px under the 600px view's end; its box moves with the translate it wears.
  last.getBoundingClientRect = () => {
    const worn = parseFloat(last.style.translate.split(" ")[1] ?? "") || 0;
    return { top: 300 + worn, bottom: 1100 + worn, height: 800 } as DOMRect;
  };
  const placed = new Map<HTMLElement, number>(rows.map((each) => [each, 100]));
  placed.set(row, 700);
  const height = new Map(placed);
  const ride = new FoldRide({
    placed: (each) => placed.get(each),
    height: (each) => height.get(each),
    finish: () => {},
  });
  markHeightFold(row, 10_000);

  // A close, frame by frame: the last row rides to 1060, then 800, both under the view's end.
  height.set(row, 660);
  expect(ride.ride([row])).toBe(true);
  expect(last.style.translate).toBe("0 -40px");
  height.set(row, 400);
  expect(ride.ride([row])).toBe(true);
  expect(under.style.translate).toBe("0 -300px");
  expect(last.style.translate).toBe("0 -300px");
  // The next frame would end it at 550, over the view's end at 600: the transcript places the end.
  height.set(row, 150);
  expect(ride.ride([row])).toBe(false);
  expect(under.style.translate).toBe("");
  expect(last.style.translate).toBe("");

  // An open with the last row as far under the view's end rides too (this fake keeps the last row
  // at 1100; in the app it is at 550 after that close, and an open from there gives way).
  ride.release();
  placed.set(row, 150);
  height.set(row, 190);
  expect(ride.ride([row])).toBe(true);
  expect(last.style.translate).toBe("0 40px");
});
