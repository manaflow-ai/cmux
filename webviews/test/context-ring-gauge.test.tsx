// The composer's context ring always reads as a gauge, never a loading spinner. Leo (2026-11-03) read
// the ring at 68% (a faint 30% track under a round-ended arc) as a spinner: "and why does it even take
// time to read settings? you know what things are". The shipped look (experiment context-ring-look,
// arm `track`) draws the remaining share as a clearly visible track and the used arc with flat ends,
// so the whole circle reads as one gauge with no gap. Never a pie, and the ring never animates.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextRing } from "../src/agent-session/acpmux/ComposerPickers";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function ring(used: number | undefined, size = 200_000) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<ContextRing used={used} size={used === undefined ? undefined : size} />);
  });
  const svg = container.querySelector(".acpmux-context-ring svg")!;
  const circles = [...svg.querySelectorAll("circle")];
  return { svg, track: circles[0]!, used: circles[1], container };
}

for (const share of [0.25, 0.68, 0.95]) {
  test(`at ${Math.round(share * 100)}% the remaining share is a visible track and the arc has flat ends`, async () => {
    const { track, used } = await ring(share * 200_000);
    // The track carries at least half the arc's ink, so the circle never reads as a lone arc.
    expect(Number(track.getAttribute("stroke-opacity"))).toBeGreaterThanOrEqual(0.5);
    expect(used).toBeDefined();
    const usedOpacity = Number(used!.getAttribute("stroke-opacity") ?? 1);
    expect(usedOpacity).toBeGreaterThan(Number(track.getAttribute("stroke-opacity")));
    // Flat ends: the arc meets the track, with no rounded tail like a spinner's.
    expect(used!.getAttribute("stroke-linecap")).toBe("butt");
    // Same radius and width: one ring, never a pie.
    expect(used!.getAttribute("r")).toBe(track.getAttribute("r"));
    expect(used!.getAttribute("fill")).toBe("none");
    expect(track.getAttribute("fill")).toBe("none");
  });
}

test("the ring is static: no animation or transition on its arc", async () => {
  const { svg } = await ring(0.68 * 200_000);
  expect(svg.querySelector("animate, animateTransform")).toBeNull();
  for (const circle of svg.querySelectorAll("circle"))
    expect(circle.getAttribute("style") ?? "").not.toMatch(/anim|transition/);
});

test("before usage is known the ring is the inert track alone", async () => {
  const { track, used, container } = await ring(undefined);
  expect(used).toBeUndefined();
  expect(track).toBeDefined();
  // Off but not `disabled`: its right-click menu still has to open (UsageRingMenu), so a click is inert.
  const button = container.querySelector<HTMLButtonElement>(".acpmux-context-ring")!;
  expect(button.getAttribute("aria-disabled")).toBe("true");
  await act(async () => button.click());
  expect(button.getAttribute("aria-expanded")).toBe("false");
  // No caption in the shipped look.
  expect(container.querySelector(".acpmux-context-caption")).toBeNull();
});
