// The page side of the feel harness: one read per painted frame (support/paintedFrames.ts) of every
// tracked box, live text and state, the pointer as the page last heard it, and the layout shift the
// browser scored, plus every pointer and click event on the same clock. It runs only between
// `start` and `stop` (one after-paint read a frame while it records, nothing after).
import type { Page } from "playwright";
import { installPaintedFrames } from "../support/paintedFrames";
import type { FeelTrace, ProbeSpec } from "./trace";

declare global {
  interface Window {
    cmuxFeel?: { start: (spec: ProbeSpec) => void; stop: () => FeelTrace; read: () => FeelTrace["frames"][number] };
  }
}

/** The page side; runs in the page, so it closes over nothing. */
function defineFeelProbe() {
  if (window.cmuxFeel) return;
  type Spec = ProbeSpec;
  type Trace = FeelTrace;
  let pointer: { x: number; y: number; buttons: number } | null = null;
  let events: Trace["events"] = [];
  let frames: Trace["frames"] = [];
  let shift = 0;
  let stopRead: (() => void) | undefined;
  let spec: Spec = {};
  const heard = (event: Event) => {
    const e = event as PointerEvent;
    pointer = { x: e.clientX, y: e.clientY, buttons: e.buttons };
    if (stopRead)
      events.push({
        t: performance.now(),
        type: e.type,
        x: e.clientX,
        y: e.clientY,
        buttons: e.buttons,
        detail: e.detail,
      });
  };
  // Capturing on the window, before any of the page's handlers: what the person did, not what the
  // page made of it.
  for (const kind of ["pointerdown", "pointermove", "pointerup", "pointercancel", "click", "dblclick"])
    addEventListener(kind, heard, { capture: true, passive: true });
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) shift += (entry as unknown as { value: number }).value;
    }).observe({ type: "layout-shift", buffered: false });
  } catch {
    // Not Chromium: no layout-shift scores, every frame reads 0.
  }
  // The words a reader sees: the element's text without what a transition keeps for its leaving
  // part (`aria-hidden`, as trayMotion.tsx's outgoing words are), and the width it is drawn at.
  const shownText = (element: Element): string => {
    let text = "";
    const walk = (node: Node) => {
      if (node.nodeType === Node.TEXT_NODE) text += node.textContent ?? "";
      else if (node instanceof Element && node.getAttribute("aria-hidden") === "true") return;
      else for (const child of node.childNodes) walk(child);
    };
    walk(element);
    return text;
  };
  const textWidth = (element: Element) => Math.round(element.getBoundingClientRect().width * 10) / 10;
  const read = (t: number): Trace["frames"][number] => {
    const boxes: Trace["frames"][number]["boxes"] = {};
    for (const [name, selector] of Object.entries(spec.boxes ?? {})) {
      const element = document.querySelector(selector);
      if (!element) {
        boxes[name] = null;
        continue;
      }
      const rect = element.getBoundingClientRect();
      boxes[name] = { x: rect.x, y: rect.y, w: rect.width, h: rect.height };
    }
    const texts: Trace["frames"][number]["texts"] = {};
    for (const [name, selector] of Object.entries(spec.texts ?? {})) {
      const element = document.querySelector(selector);
      texts[name] = element ? { text: shownText(element), width: textWidth(element) } : null;
    }
    const states: Trace["frames"][number]["states"] = {};
    for (const [name, { selector, attr }] of Object.entries(spec.states ?? {})) {
      const element = document.querySelector(selector);
      states[name] = !element ? null : attr === undefined ? "1" : element.getAttribute(attr);
    }
    const frame = { t, pointer: pointer && { ...pointer }, boxes, texts, states, shift };
    shift = 0;
    return frame;
  };
  window.cmuxFeel = {
    start(next) {
      stopRead?.();
      spec = next;
      frames = [];
      events = [];
      shift = 0;
      stopRead = window.cmuxAfterPaint((t) => {
        frames.push(read(t));
      });
    },
    stop() {
      stopRead?.();
      stopRead = undefined;
      return { frames, events };
    },
    read: () => read(performance.now()),
  };
}

/** Puts the probe (and the painted-frame reader it rides on) in `page`'s current and later documents. */
export async function installFeelProbe(page: Page): Promise<void> {
  await installPaintedFrames(page);
  await page.addInitScript(defineFeelProbe);
  await page.evaluate(defineFeelProbe);
}

/** Records what `act` does: every painted frame from just before it until `settleFrames` frames after. */
export async function record(
  page: Page,
  spec: ProbeSpec,
  act: () => Promise<void>,
  { settleFrames = 20 }: { settleFrames?: number } = {},
): Promise<FeelTrace> {
  await page.evaluate((s) => window.cmuxFeel!.start(s), spec);
  await frames(page, 2);
  await act();
  await frames(page, settleFrames);
  return page.evaluate(() => window.cmuxFeel!.stop());
}

/** Waits for `count` painted frames. */
export async function frames(page: Page, count = 1): Promise<void> {
  await page.evaluate(async (n) => {
    for (let i = 0; i < n; i++) await window.cmuxPaintFrame();
  }, count);
}
