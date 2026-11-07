// The App draws a floating surface's glass under a see-through Chromium page (ui/glass/hostGlass.ts;
// Leo, 2026-11-06: "why the f*** is this not glass? Like the way the native menus are"). A marked
// surface is reported with its box, level, radius and opacity, draws nothing until the App has drawn
// its glass, keeps the page's own glass past the deadline or when the App refuses, and its report is
// withdrawn when it goes.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  HOST_GLASS_DEADLINE_MS,
  HOST_GLASS_DRAWN_ATTRIBUTE,
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

const frames = (count = 2) =>
  new Promise<void>((resolve) => {
    const step = (left: number) => (left === 0 ? resolve() : dom!.window.requestAnimationFrame(() => step(left - 1)));
    step(count);
  });
// fixed-wait: the deadline is the behavior under test (a surface the App has not drawn in time).
const pastDeadline = () => new Promise((resolve) => setTimeout(resolve, HOST_GLASS_DEADLINE_MS + 20));
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

test("a marked surface is reported and draws only once the App drew its glass", async () => {
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
  // Not answered yet: glass.css keeps it hidden (no drawn mark).
  expect(element.hasAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe(false);
  answer!();
  await settled();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("1");
});

test("a surface the App has not drawn by the deadline keeps the page's own glass", async () => {
  const doc = page();
  stop = reportHostGlass(doc, () => new Promise(() => undefined));
  const element = surface(doc);
  await frames();
  expect(element.hasAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe(false);
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
  // The App answers the report sent while host glass applied.
  answers[0]!();
  await settled();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).not.toBe("1");
  window.requestAnimationFrame = paint;
  await frames();
  expect(element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE)).toBe("0");
});

test("a surface whose report changes every frame is drawn on an answer to an earlier report", async () => {
  const doc = page();
  const answers: (() => void)[] = [];
  stop = reportHostGlass(doc, () => new Promise<void>((resolve) => answers.push(resolve)));
  const element = surface(doc);
  await frames(1);
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
