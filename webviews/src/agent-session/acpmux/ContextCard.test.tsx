// The context ring's hover card (Leo 2026-10-21, after Claude's and Codex's): resting on the ring,
// or focusing it from the keyboard, shows a glass card with no click. It reads "23% used · 111k /
// 475k", draws the window as a thin stacked bar (setup, then conversation, over the free track,
// in the Inspector Context meter's colors) and ends on "Details ›", which opens the Inspector at
// its Context section. The ring itself never takes a hover pill.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextRing } from "./ComposerPickers";
import { translate } from "./i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(Date.now()), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function wait(ms = 0) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

async function mount(props: Parameters<typeof ContextRing>[0]) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<ContextRing {...props} />);
  });
  return container.querySelector<HTMLButtonElement>(".acpmux-context-ring")!;
}

const card = () => document.querySelector<HTMLElement>(".acpmux-context-card");

/// Lets React and the hover timers run, one macrotask at a time, until `done` or `capMs` passes.
async function until(done: () => boolean, capMs = 3000) {
  const deadline = Date.now() + capMs;
  while (!done() && Date.now() < deadline) await wait();
}

test("resting the pointer on the ring shows the card without a click", async () => {
  const ring = await mount({ used: 111_000, size: 475_000 });
  expect(card()).toBeNull();
  await act(async () => {
    ring.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
  });
  await until(() => card() !== null);
  expect(card()).not.toBeNull();
  expect(document.querySelector(".acpmux-context-pop")).toBeNull();
});

test("keyboard focus opens the card at once, with the context line and a stacked bar", async () => {
  const ring = await mount({ used: 111_000, size: 475_000, setup: 20_000 });
  await act(async () => ring.focus());
  await wait();
  const shown = card();
  expect(shown).not.toBeNull();
  expect(shown!.textContent).toContain(translate("context.title"));
  const line = shown!.querySelector(".acpmux-context-card-line")!.textContent;
  expect(line).toContain("23%");
  expect(line).toMatch(/111K/i);
  expect(line).toMatch(/475K/i);
  const segments = [...shown!.querySelectorAll<HTMLElement>(".acpmux-context-card-bar [data-segment]")];
  expect(segments.map((segment) => segment.dataset.segment)).toEqual(["setup", "conversation"]);
  // 20k and 91k of 475k.
  expect(parseFloat(segments[0].style.width)).toBeCloseTo(4.2, 1);
  expect(parseFloat(segments[1].style.width)).toBeCloseTo(19.2, 1);
});

test("without a setup split the bar is one used segment", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => ring.focus());
  await wait();
  const segments = [...card()!.querySelectorAll<HTMLElement>(".acpmux-context-card-bar [data-segment]")];
  expect(segments.map((segment) => segment.dataset.segment)).toEqual(["used"]);
  expect(parseFloat(segments[0].style.width)).toBeCloseTo(30, 1);
});

test("the card shows no plan-limits section when the harness reports none", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => ring.focus());
  await wait();
  expect(card()!.querySelector(".acpmux-context-card-limits")).toBeNull();
});

test("Details › opens the Inspector's Context section", async () => {
  let opened = 0;
  const ring = await mount({ used: 60_000, size: 200_000, onOpenDetails: () => opened++ });
  await act(async () => ring.focus());
  await wait();
  const details = card()!.querySelector<HTMLButtonElement>(".acpmux-context-card-details")!;
  expect(details.textContent).toContain(translate("context.details"));
  expect(details.textContent).toContain("›");
  await act(async () => details.click());
  expect(opened).toBe(1);
});

test("with nowhere to open, the card has no Details link", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => ring.focus());
  await wait();
  expect(card()!.querySelector(".acpmux-context-card-details")).toBeNull();
});

test("before the first usage report the ring is inert and shows no card", async () => {
  const ring = await mount({});
  await act(async () => ring.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true })));
  // fixed-wait: proving no card shows means outwaiting the hover delay (450 ms) once.
  await wait(600);
  expect(card()).toBeNull();
});

test("the ring takes no hover or open pill in any stylesheet", () => {
  const dir = import.meta.dir;
  const css = ["styles.css", "composerLocation.css", "composerControls.css", "contextCard.css"]
    .map((file) => {
      try {
        return readFileSync(join(dir, file), "utf8");
      } catch {
        return "";
      }
    })
    .join("\n")
    .replace(/\/\*[\s\S]*?\*\//g, "");
  const offenders: string[] = [];
  for (const match of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = match[1].split(",").map((selector) => selector.trim());
    const ringStates = selectors.filter(
      (selector) => /\.acpmux-context-ring(?![\w-])/.test(selector) && /:hover|\[aria-expanded/.test(selector),
    );
    if (ringStates.length === 0) continue;
    const fill = /(?:^|;)\s*background(?:-color)?\s*:\s*([^;]+)/.exec(match[2]);
    if (fill && !/^(none|transparent)\s*$/.test(fill[1].trim()))
      offenders.push(`${ringStates.join(", ")} -> ${fill[1]}`);
  }
  expect(offenders).toEqual([]);
});
