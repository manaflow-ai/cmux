// The glass host's web half (index.ts): open/position/resize/close reach the app as whole-list reports
// coalesced per frame, a surface is pending until the app drew it, falls back past the deadline or on a
// refusal and then stays on the page's look, and an attached element follows its own box.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  createGlassHost,
  PHASE_ATTRIBUTE,
  type GlassHost,
  type GlassHostWindow,
  type GlassSurfaceState,
} from "./index";

let dom: JSDOM | undefined;
let host: GlassHost | undefined;

type TestWindow = GlassHostWindow & { Event: typeof Event };

function page(): TestWindow {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true });
  return dom.window as unknown as TestWindow;
}

const frames = (view: Window, count = 2) =>
  new Promise<void>((resolve) => {
    const step = (left: number) => (left === 0 ? resolve() : view.requestAnimationFrame(() => step(left - 1)));
    step(count);
  });
const settled = async () => {
  for (let i = 0; i < 3; i += 1) await Promise.resolve();
};

afterEach(() => {
  host?.destroy();
  host = undefined;
  dom?.window.close();
  dom = undefined;
});

test("open, position, resize and close reach the app as one coalesced report per frame", async () => {
  const view = page();
  const reports: GlassSurfaceState[][] = [];
  host = createGlassHost({ view, transport: (surfaces) => (reports.push(surfaces), Promise.resolve()) });
  const surface = host.open({ level: "menu", rect: { left: 10, top: 20, right: 110, bottom: 220 }, radius: 8 });
  surface.position({ left: 30, top: 40, right: 130, bottom: 240 });
  surface.resize(200, 100);
  await frames(view);
  expect(reports).toEqual([
    [{ id: surface.id, level: "menu", left: 30, top: 40, right: 230, bottom: 140, radius: 8, opacity: 1 }],
  ]);
  expect(await surface.ready).toBe(true);
  expect(surface.phase).toBe("drawn");
  surface.close();
  await frames(view);
  expect(reports.at(-1)).toEqual([]);
});

test("a surface the app has not drawn by the deadline falls back and is no longer reported", async () => {
  const view = page();
  const reports: GlassSurfaceState[][] = [];
  host = createGlassHost({
    view,
    deadlineMs: 10,
    transport: (surfaces) => (reports.push(surfaces), new Promise(() => undefined)),
  });
  const surface = host.open({ rect: { left: 0, top: 0, right: 50, bottom: 50 } });
  expect(await surface.ready).toBe(false);
  expect(surface.phase).toBe("fallback");
  // Nothing about it changed: the fallback alone sends the list without it.
  await settled();
  expect(reports.at(-1)).toEqual([]);
});

test("a directly attached element follows a scroll that moves it and goes when it leaves the document", async () => {
  const view = page();
  const doc = view.document;
  const element = doc.createElement("div");
  doc.body.append(element);
  let box = { left: 40, top: 60, right: 240, bottom: 180 };
  (element as unknown as { getBoundingClientRect: () => DOMRect }).getBoundingClientRect = () =>
    ({ ...box, width: box.right - box.left, height: box.bottom - box.top, x: box.left, y: box.top }) as DOMRect;
  const reports: GlassSurfaceState[][] = [];
  host = createGlassHost({ view, transport: (s) => (reports.push(s), Promise.resolve()) });
  host.attach(element, { level: "menu" });
  await frames(view, 5);
  expect(reports.at(-1)?.[0]).toMatchObject({ level: "menu", top: 60 });
  // Long after it settled, a scroll moves it with no resize.
  box = { left: 40, top: 20, right: 240, bottom: 140 };
  view.dispatchEvent(new view.Event("scroll"));
  await frames(view);
  expect(reports.at(-1)?.[0]).toMatchObject({ top: 20 });
  element.remove();
  await settled();
  await frames(view, 3);
  expect(reports.at(-1)).toEqual([]);
});

test("a refusal falls every surface back and ends the reports", async () => {
  const view = page();
  let calls = 0;
  host = createGlassHost({ view, transport: () => (calls++, Promise.reject(new Error("unknown call"))) });
  const first = host.open({ rect: { left: 0, top: 0, right: 50, bottom: 50 } });
  await frames(view);
  await settled();
  expect(first.phase).toBe("fallback");
  expect(host.live).toBe(false);
  const second = host.open({ rect: { left: 0, top: 0, right: 50, bottom: 50 } });
  expect(second.phase).toBe("fallback");
  await frames(view);
  expect(calls).toBe(1);
});

test("an app that does not apply now reports nothing and falls surfaces back", async () => {
  const view = page();
  const reports: GlassSurfaceState[][] = [];
  host = createGlassHost({ view, applies: () => false, transport: (s) => (reports.push(s), Promise.resolve()) });
  const surface = host.open({ rect: { left: 0, top: 0, right: 50, bottom: 50 } });
  await frames(view);
  expect(reports).toEqual([]);
  expect(surface.phase).toBe("fallback");
});

test("an attached element follows its box, carries its phase, and goes when it unmounts", async () => {
  const view = page();
  const doc = view.document;
  const element = doc.createElement("div");
  element.setAttribute("data-glass-level", "popover");
  element.style.borderTopLeftRadius = "12px";
  doc.body.append(element);
  let box = { left: 40, top: 60, right: 240, bottom: 180 };
  (element as unknown as { getBoundingClientRect: () => DOMRect }).getBoundingClientRect = () =>
    ({ ...box, width: box.right - box.left, height: box.bottom - box.top, x: box.left, y: box.top }) as DOMRect;
  const reports: GlassSurfaceState[][] = [];
  host = createGlassHost({ view, transport: (s) => (reports.push(s), Promise.resolve()) });
  const stop = host.observe();
  expect(element.getAttribute(PHASE_ATTRIBUTE)).toBe("pending");
  await frames(view);
  await settled();
  expect(reports.at(-1)?.[0]).toMatchObject({ level: "popover", left: 40, top: 60, radius: 12 });
  expect(element.getAttribute(PHASE_ATTRIBUTE)).toBe("drawn");
  box = { left: 100, top: 60, right: 300, bottom: 180 };
  host.surfaces[0]!.setOpacity(1);
  await frames(view);
  expect(reports.at(-1)?.[0]).toMatchObject({ left: 100, right: 300 });
  element.remove();
  await frames(view, 3);
  expect(reports.at(-1)).toEqual([]);
  stop();
});

test("destroy sends the empty report once", async () => {
  const view = page();
  const reports: GlassSurfaceState[][] = [];
  const own = createGlassHost({ view, transport: (s) => (reports.push(s), Promise.resolve()) });
  own.open({ rect: { left: 0, top: 0, right: 10, bottom: 10 } });
  await frames(view);
  own.destroy();
  expect(reports.at(-1)).toEqual([]);
  expect(own.live).toBe(false);
});
