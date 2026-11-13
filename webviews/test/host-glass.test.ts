// The App draws a floating surface's glass under a see-through Chromium page (ui/glass/hostGlass.ts;
// Leo, 2026-11-06: "why the f*** is this not glass? Like the way the native menus are"). A marked
// surface is reported with its box, level, radius and opacity, shows its content in the frame it
// mounts (Leo, 2026-11-09: "it loads the placeholder, THEN the content... every single time"), keeps
// the page's own glass past the deadline or when the App refuses, and its report is withdrawn in the
// task it goes in. Its box goes to the App only once its content has been on screen for the hold, so
// the App's glass never shows before the content (Leo, 2026-11-09, on the empty glass box before menus).
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  HOST_GLASS_DEADLINE_MS,
  HOST_GLASS_DRAWN_ATTRIBUTE,
  HOST_GLASS_HOLD_FRAMES,
  HOST_GLASS_MAX,
  HOST_GLASS_ROOT_ATTRIBUTE,
  hostGlassApplies,
  reportHostGlass,
  type HostGlassSurface,
} from "../src/ui/glass/hostGlass";

let dom: JSDOM | undefined;
let stop: (() => void) | undefined;

function page({ seeThrough = true, chromium = true } = {}): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const window = dom.window as unknown as Window & typeof globalThis;
  // Chromium has no -webkit-backdrop-filter; WebKit does.
  Object.defineProperty(window, "CSS", { value: { supports: () => !chromium }, configurable: true });
  // JSDOM has no ResizeObserver; the in-place blur needs one to follow its surface.
  (window as unknown as { ResizeObserver: unknown }).ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  const doc = window.document;
  if (seeThrough) doc.documentElement.setAttribute("data-cmux-see-through", "");
  // JSDOM lays nothing out: a marked surface sits at 40,60, 200 x 120.
  const base = window.Element.prototype.getBoundingClientRect;
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    if (this.hasAttribute("data-host-glass"))
      return { left: 40, top: 60, right: 240, bottom: 180, width: 200, height: 120, x: 40, y: 60 } as DOMRect;
    return base.call(this);
  };
  return doc;
}

function surface(doc: Document, level = "popover"): HTMLElement {
  const element = doc.createElement("aside");
  element.className = "ui-glass";
  element.setAttribute("data-host-glass", level);
  element.style.borderTopLeftRadius = "12px";
  doc.getElementById("root")!.append(element);
  return element;
}

const frames = (count = HOST_GLASS_HOLD_FRAMES + 2) =>
  new Promise<void>((resolve) => {
    const step = (left: number) => (left === 0 ? resolve() : dom!.window.requestAnimationFrame(() => step(left - 1)));
    step(count);
  });
// fixed-wait: the deadline is the behavior under test (a surface the App has not drawn in time).
const pastDeadline = () => new Promise((resolve) => setTimeout(resolve, HOST_GLASS_DEADLINE_MS + 20));
/** The App's answer arriving as a task queued now: test input, behind any timer already due. */
const answerInALaterTask = (answer: () => void) => void setTimeout(answer, 0);
/** The App's answer settles on the microtask queue. */
const settled = async () => {
  for (let i = 0; i < 3; i += 1) await Promise.resolve();
};

afterEach(() => {
  stop?.();
  stop = undefined;
  dom?.window.close();
  dom = undefined;
});

test("a marked surface is reported and shows its content before the App answers", async () => {
  const doc = page();
  const reports: HostGlassSurface[][] = [];
  let answer: (() => void) | undefined;
  stop = reportHostGlass(doc, (surfaces) => {
    reports.push(surfaces);
    return new Promise<void>((resolve) => (answer = resolve));
  });
  const element = surface(doc);
  await frames();
  expect(doc.documentElement.hasAttribute(HOST_GLASS_ROOT_ATTRIBUTE)).toBe(true);
  expect(reports.at(-1)).toEqual([
    { id: "g1", level: "popover", left: 40, top: 60, right: 240, bottom: 180, radius: 12, opacity: 1 },
  ]);
  // Not answered yet: it already draws its content on the App's glass, which the App put there on the report.
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
  answer!();
  await settled();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

test("a surface the App has not drawn by the deadline keeps the page's own glass", async () => {
  const doc = page();
  stop = reportHostGlass(doc, () => new Promise(() => undefined));
  const element = surface(doc);
  await frames();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
  await pastDeadline();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
});

test("a late answer leaves a fallen-back surface on the page's glass, and it is no longer reported", async () => {
  const doc = page();
  const reports: HostGlassSurface[][] = [];
  let answer: (() => void) | undefined;
  stop = reportHostGlass(doc, (surfaces) => {
    reports.push(surfaces);
    return new Promise<void>((resolve) => (answer ??= resolve));
  });
  const element = surface(doc);
  await frames();
  await pastDeadline();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
  answer!();
  await settled();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
  await frames();
  expect(reports.at(-1)).toEqual([]);
});

test("a surface that fell back while host glass did not apply goes back to the App's glass when it does", async () => {
  const doc = page();
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, (surfaces) => (reports.push(surfaces), Promise.resolve()));
  const element = surface(doc);
  await frames();
  await settled();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
  // Reduce Transparency turns on: the page's own glass.
  doc.documentElement.setAttribute("data-reduce-transparency", "");
  element.style.borderTopLeftRadius = "13px";
  await frames();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
  // And off again: the App's glass, reported and drawn.
  doc.documentElement.removeAttribute("data-reduce-transparency");
  element.style.borderTopLeftRadius = "12px";
  await frames();
  await settled();
  expect(reports.at(-1)).toHaveLength(1);
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

test("an App that refuses the report leaves every surface on the page's glass and is not asked again", async () => {
  const doc = page();
  let calls = 0;
  stop = reportHostGlass(doc, () => {
    calls += 1;
    return Promise.reject(new Error("unsupported"));
  });
  const first = surface(doc);
  await frames();
  await settled();
  expect(first.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
  expect(doc.documentElement.hasAttribute(HOST_GLASS_ROOT_ATTRIBUTE)).toBe(false);
  const second = surface(doc, "menu");
  await frames();
  expect(second.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
  expect(calls).toBe(1);
});

test("a surface that goes is withdrawn, and the stop withdraws the rest", async () => {
  const doc = page();
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, (surfaces) => {
    reports.push(surfaces);
    return Promise.resolve();
  });
  const one = surface(doc);
  surface(doc, "menu");
  await frames();
  expect(reports.at(-1)?.map((entry) => entry.level)).toEqual(["popover", "menu"]);
  one.remove();
  await frames();
  expect(reports.at(-1)?.map((entry) => entry.level)).toEqual(["menu"]);
  stop();
  stop = undefined;
  expect(reports.at(-1)).toEqual([]);
});

test("only a see-through Chromium page gets the App's glass", () => {
  expect(hostGlassApplies(page())).toBe(true);
  expect(hostGlassApplies(page({ seeThrough: false }))).toBe(false);
  expect(hostGlassApplies(page({ chromium: false }))).toBe(false);
  const lens = page();
  lens.documentElement.setAttribute("data-glass-lens", "");
  expect(hostGlassApplies(lens)).toBe(false);
  const reduced = page();
  reduced.documentElement.setAttribute("data-reduce-transparency", "");
  expect(hostGlassApplies(reduced)).toBe(false);
  // The live background's canvas covers what is under the page, as the lens's does.
  const live = page();
  live.documentElement.setAttribute("data-live-background", "");
  expect(hostGlassApplies(live)).toBe(false);
});

test("an opaque page reports nothing and its surfaces keep the page's glass", async () => {
  const doc = page({ seeThrough: false });
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, (surfaces) => {
    reports.push(surfaces);
    return Promise.resolve();
  });
  const element = surface(doc);
  await frames();
  expect(reports).toEqual([]);
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
});

test("a surface that misses the deadline after measuring settled is withdrawn from the report", async () => {
  const doc = page();
  // At 120 Hz the unchanged frames run out well before the deadline.
  const window = dom!.window as unknown as Window;
  window.requestAnimationFrame = (callback) => window.setTimeout(() => callback(performance.now()), 8);
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, (surfaces) => (reports.push(surfaces), new Promise(() => undefined)));
  surface(doc);
  await frames(5);
  expect(reports.at(-1)).toHaveLength(1);
  await pastDeadline();
  await frames();
  expect(reports.at(-1)).toEqual([]);
});

test("a drawn cover surface blurs the page under it in place, and stops when it goes", async () => {
  const doc = page();
  const transcript = doc.createElement("section");
  doc.getElementById("root")!.append(transcript);
  const window = dom!.window;
  const base = window.Element.prototype.getBoundingClientRect;
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    if (this === transcript)
      return { left: 0, top: 0, right: 600, bottom: 400, width: 600, height: 400, x: 0, y: 0 } as DOMRect;
    return base.call(this);
  };
  stop = reportHostGlass(doc, () => Promise.resolve(), { candidates: () => [transcript] });
  const menu = surface(doc, "menu");
  menu.setAttribute("data-host-glass-cover", "");
  await frames();
  await settled();
  await frames();
  expect(menu.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
  expect(transcript.hasAttribute("data-glass-under")).toBe(true);
  expect(menu.hasAttribute("data-glass-over")).toBe(true);
  menu.remove();
  await frames();
  expect(transcript.hasAttribute("data-glass-under")).toBe(false);
});

test("a surface whose deadline passes as host glass stops applying goes to the App's glass when it applies again", async () => {
  const doc = page();
  const reports: HostGlassSurface[][] = [];
  // The App has not answered yet when Reduce Transparency turns on.
  let answer = () => {};
  stop = reportHostGlass(
    doc,
    (surfaces) => (reports.push(surfaces), new Promise<void>((resolve) => (answer = resolve))),
  );
  const element = surface(doc);
  await frames();
  // The deadline comes before the next frame measures the page's new look.
  const window = dom!.window as unknown as Window;
  const paint = window.requestAnimationFrame;
  window.requestAnimationFrame = () => 0;
  doc.documentElement.setAttribute("data-reduce-transparency", "");
  await pastDeadline();
  window.requestAnimationFrame = paint;
  await frames();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
  // Reduce Transparency turns off with the surface still open: it is reported and drawn.
  doc.documentElement.removeAttribute("data-reduce-transparency");
  await frames();
  answer();
  await settled();
  expect(reports.at(-1)).toHaveLength(1);
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

test("an answer that comes after host glass stopped applying never marks the surface drawn", async () => {
  const doc = page();
  const answers: (() => void)[] = [];
  stop = reportHostGlass(doc, () => new Promise<void>((resolve) => answers.push(resolve)));
  const element = surface(doc);
  await frames();
  // Reduce Transparency turns on and the deadline passes before any frame measures again.
  const window = dom!.window as unknown as Window;
  const paint = window.requestAnimationFrame;
  window.requestAnimationFrame = () => 0;
  doc.documentElement.setAttribute("data-reduce-transparency", "");
  await pastDeadline();
  window.requestAnimationFrame = paint;
  await frames();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
  // The App answers the report sent while host glass applied: the page's glass stays.
  answers[0]!();
  await settled();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
});

test("a surface whose report changes every frame is drawn on an answer to an earlier report", async () => {
  const doc = page();
  const answers: (() => void)[] = [];
  stop = reportHostGlass(doc, () => new Promise<void>((resolve) => answers.push(resolve)));
  const element = surface(doc);
  await frames(HOST_GLASS_HOLD_FRAMES + 1);
  // The surface moves (a scroll, a fade) and a new report goes out before the first is answered.
  const window = dom!.window as unknown as Window & typeof globalThis;
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    return { left: 40, top: 70, right: 240, bottom: 190, width: 200, height: 120, x: 40, y: 70 } as DOMRect;
  };
  await frames(1);
  expect(answers.length).toBeGreaterThan(1);
  answers[0]!();
  await settled();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

test("a new surface is marked in the task it mounts in, before any frame paints it", async () => {
  const doc = page();
  stop = reportHostGlass(doc, () => new Promise(() => undefined));
  const element = surface(doc);
  // The observer's microtask, not a frame: the first frame that paints the surface paints its content.
  await Promise.resolve();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

test("a surface that goes is withdrawn in the task it goes in, so its glass leaves with its content", async () => {
  const doc = page();
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, (surfaces) => (reports.push(surfaces), Promise.resolve()));
  const one = surface(doc);
  surface(doc, "menu");
  await frames();
  expect(reports.at(-1)?.map((entry) => entry.level)).toEqual(["popover", "menu"]);
  one.remove();
  await Promise.resolve();
  expect(reports.at(-1)?.map((entry) => entry.level)).toEqual(["menu"]);
});

test("a deadline that ran late behind the page's own work leaves the queued answer time to land", async () => {
  const doc = page();
  let answer: (() => void) | undefined;
  stop = reportHostGlass(doc, () => new Promise<void>((resolve) => (answer ??= resolve)));
  const element = surface(doc);
  await frames();
  // The page is busy past the deadline (a big render after the popup mounts): the App's answer and
  // the deadline both wait behind it, and the deadline's timer runs first.
  const busyUntil = performance.now() + HOST_GLASS_DEADLINE_MS * 3;
  while (performance.now() < busyUntil) {
    // busy: the page's own work
  }
  answerInALaterTask(() => answer!());
  await pastDeadline();
  await pastDeadline();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

test("a new surface's box goes to the App only after its content has been on screen for the hold", async () => {
  const doc = page();
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, (surfaces) => (reports.push(surfaces), new Promise(() => undefined)));
  const element = surface(doc);
  // The frames that paint its content, on the page's in-place blur: the App has drawn nothing yet.
  await frames(HOST_GLASS_HOLD_FRAMES);
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
  expect(reports.flat()).toEqual([]);
  // The next frame: its content is on screen, and the App's glass goes under it.
  await frames(1);
  expect(reports.at(-1)?.map((entry) => entry.id)).toEqual(["g1"]);
});

test("the deadline starts at a surface's first report, not while it is held", async () => {
  const doc = page();
  const window = dom!.window as unknown as Window;
  // A slow display: the hold alone outlasts the deadline.
  window.requestAnimationFrame = (callback) => window.setTimeout(() => callback(performance.now()), 40);
  let answer: (() => void) | undefined;
  stop = reportHostGlass(doc, () => new Promise<void>((resolve) => (answer ??= resolve)));
  const element = surface(doc);
  // The mount's observer schedules the reporter's frames before the test counts its own.
  await Promise.resolve();
  await frames(HOST_GLASS_HOLD_FRAMES + 2);
  expect(answer).toBeDefined();
  answer!();
  await settled();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

// Leo, 2026-11-09, of the This Mac/Cloud/Remote and Bypass permissions menus: "What the heck is this?"
// An empty glass box stayed where the menu was after it closed. The detector: drive a surface through
// open, close fade and unmount, with an App that draws the last report it received one frame later, and
// at every step no glass (the App's, or the in-place blur) shows where the content is fading or gone.
test("no step of an open and close shows the App's glass or the blur without the surface's content", async () => {
  const doc = page();
  const transcript = doc.createElement("section");
  doc.getElementById("root")!.append(transcript);
  const window = dom!.window;
  const base = window.Element.prototype.getBoundingClientRect;
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    if (this === transcript)
      return { left: 0, top: 0, right: 600, bottom: 400, width: 600, height: 400, x: 0, y: 0 } as DOMRect;
    return base.call(this);
  };
  // The App draws a report a frame after it is sent (its own run loop), as it does on a busy pick.
  let received: HostGlassSurface[] = [];
  let drawn: HostGlassSurface[] = [];
  const posts: HostGlassSurface[][] = [];
  stop = reportHostGlass(
    doc,
    (surfaces) => {
      posts.push(surfaces);
      received = surfaces;
      return Promise.resolve();
    },
    { candidates: () => [transcript] },
  );
  const appFrame = () => {
    drawn = received;
  };
  const violations: string[] = [];
  // `painted`: a frame has painted since the step (the App drew what it had received by then).
  const check = (step: string, menu: HTMLElement, painted: boolean) => {
    // The content shows at full strength only while open: a closing surface is fading.
    const content = menu.isConnected && !menu.hasAttribute("data-ending-style");
    const blur = transcript.hasAttribute("data-glass-under");
    // What the App shows on screen, once a frame painted; before that, what is on its way to it.
    const shown = (painted ? drawn : received).some((entry) => entry.opacity > 0);
    if (!content && (shown || blur)) violations.push(`${step}: App glass ${shown} blur ${blur}`);
  };
  const menu = surface(doc, "menu");
  menu.setAttribute("data-host-glass-cover", "");
  for (let i = 0; i < 4; i += 1) {
    await frames(1);
    await settled();
    appFrame();
    check(`open ${i}`, menu, true);
  }
  expect(drawn).toHaveLength(1);
  expect(transcript.hasAttribute("data-glass-under")).toBe(true);
  // The close starts: Base UI marks the fade. The App's glass is withdrawn in this task, before any
  // frame paints the fade, and the blur leaves with it.
  const before = posts.length;
  menu.setAttribute("data-ending-style", "");
  menu.style.opacity = "0.6";
  await Promise.resolve();
  expect(posts.length).toBe(before + 1);
  expect(posts.at(-1)).toEqual([]);
  expect(transcript.hasAttribute("data-glass-under")).toBe(false);
  // It fades on the page's own glass, drawn with its content.
  expect(menu.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
  check("close start", menu, false);
  for (const opacity of ["0.3", "0"]) {
    menu.style.opacity = opacity;
    await frames(1);
    await settled();
    appFrame();
    check(`fade ${opacity}`, menu, true);
  }
  expect(drawn).toEqual([]);
  menu.remove();
  await frames(1);
  appFrame();
  check("gone", menu, true);
  expect(violations).toEqual([]);
});

test("a surface that closes and opens again during its hold gets its deadline at its first report", async () => {
  const doc = page();
  const window = dom!.window as unknown as Window;
  // A slow display: the hold alone outlasts the deadline.
  window.requestAnimationFrame = (callback) => window.setTimeout(() => callback(performance.now()), 40);
  let answer: (() => void) | undefined;
  stop = reportHostGlass(doc, (surfaces) =>
    surfaces.length > 0 ? new Promise<void>((resolve) => (answer ??= resolve)) : Promise.resolve(),
  );
  // Each step in its own task, so the reporter sees the mount, the close and the reopen in turn.
  // fixed-wait: a zero-delay task, not a sleep; it only orders the steps after the observer.
  const task = () => new Promise((resolve) => setTimeout(resolve, 0));
  const menu = surface(doc, "menu");
  await task();
  menu.setAttribute("data-ending-style", "");
  await task();
  menu.removeAttribute("data-ending-style");
  await frames(HOST_GLASS_HOLD_FRAMES + 2);
  expect(answer).toBeDefined();
  answer!();
  await settled();
  expect(menu.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

test("a surface that opens again during its close fade goes back on the App's glass", async () => {
  const doc = page();
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, (surfaces) => (reports.push(surfaces), Promise.resolve()));
  const menu = surface(doc, "menu");
  await frames();
  await settled();
  menu.setAttribute("data-ending-style", "");
  await Promise.resolve();
  expect(reports.at(-1)).toEqual([]);
  menu.removeAttribute("data-ending-style");
  await frames();
  await settled();
  expect(reports.at(-1)).toHaveLength(1);
  expect(menu.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

test("a surface that opens again during its fade before the App answered still falls back past the deadline", async () => {
  const doc = page();
  stop = reportHostGlass(doc, () => new Promise(() => undefined));
  const menu = surface(doc, "menu");
  await frames();
  menu.setAttribute("data-ending-style", "");
  await Promise.resolve();
  // The first deadline passes while it closes, then it opens again.
  await pastDeadline();
  menu.removeAttribute("data-ending-style");
  // Reported again at once (its content was on screen): two frames are inside its new deadline.
  await frames(2);
  expect(menu.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
  await pastDeadline();
  expect(menu.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
});

test("a surface the App had answered for, opened again during its fade, still falls back if the App stalls", async () => {
  const doc = page();
  let calls = 0;
  stop = reportHostGlass(doc, () => (++calls === 1 ? Promise.resolve() : new Promise(() => undefined)));
  const menu = surface(doc, "menu");
  await frames();
  await settled();
  expect(menu.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
  menu.setAttribute("data-ending-style", "");
  await Promise.resolve();
  menu.removeAttribute("data-ending-style");
  // Reported again at once (its content was on screen): two frames are inside its new deadline.
  await frames(2);
  expect(menu.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
  await pastDeadline();
  expect(menu.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
});

test("a surface past what one report carries keeps the page's own glass", async () => {
  const doc = page();
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, (surfaces) => (reports.push(surfaces), Promise.resolve()));
  const all = Array.from({ length: HOST_GLASS_MAX + 1 }, () => surface(doc));
  await frames();
  await settled();
  expect(reports.at(-1)).toHaveLength(HOST_GLASS_MAX);
  const drawn = all.map((element) => element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE));
  expect(drawn.slice(0, HOST_GLASS_MAX)).toEqual(Array(HOST_GLASS_MAX).fill("1"));
  // The one past the cap is never reported, so it shows the page's glass at once, not content on no glass.
  expect(drawn.at(-1)).toBe("0");
});

/** A trackpad pinch in Chromium: the visual viewport zooms and pans, the layout does not. */
function pinch(doc: Document, scale: number, offsetLeft: number, offsetTop: number) {
  const window = doc.defaultView!;
  const visual = Object.assign(new window.EventTarget(), { scale, offsetLeft, offsetTop });
  Object.defineProperty(window, "visualViewport", { value: visual, configurable: true });
  return (next: { scale: number; offsetLeft: number; offsetTop: number }) => {
    Object.assign(visual, next);
    visual.dispatchEvent(new window.Event("resize"));
  };
}

test("under a trackpad pinch a surface is reported where it shows, so the App's glass zooms with it", async () => {
  // Leo, 2026-11-12: "when you e.g. zoom in to the ui with the trackpad it gives this super strange
  // kinda ghost glass in the back?"
  const doc = page();
  pinch(doc, 2, 10, 20);
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, async (surfaces) => void reports.push(surfaces));
  surface(doc);
  await frames();
  expect(reports.at(-1)).toEqual([
    { id: "g1", level: "popover", left: 60, top: 80, right: 460, bottom: 320, radius: 24, opacity: 1 },
  ]);
});

test("a pinch after the surface settled moves its report with no layout change", async () => {
  const doc = page();
  const zoom = pinch(doc, 1, 0, 0);
  const reports: HostGlassSurface[][] = [];
  stop = reportHostGlass(doc, async (surfaces) => void reports.push(surfaces));
  surface(doc);
  await frames(HOST_GLASS_HOLD_FRAMES + 6);
  expect(reports.at(-1)?.[0]).toMatchObject({ left: 40, top: 60, right: 240, bottom: 180, radius: 12 });
  zoom({ scale: 1.5, offsetLeft: 0, offsetTop: 0 });
  await frames();
  expect(reports.at(-1)?.[0]).toMatchObject({ left: 60, top: 90, right: 360, bottom: 270, radius: 18 });
});
