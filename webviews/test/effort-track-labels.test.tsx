// l10n-allow-file: test labels only.
// The effort slider's ends and default (cx-ncc.83, Claude parity): the track reads Faster at its
// low end and Smarter at its high end, and names the level the running model recommends (its
// catalog default), which the slider also speaks when it sits there.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// The code card's highlighter (@pierre/diffs) defines its elements, which read DOM constructors, on import.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const window = dom.window;
const host = window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const text = (selector: string) => host.querySelector(selector)?.textContent ?? null;

test("the compact effort slider exposes its range and recommended level", async () => {
  const { createRoot } = await import("react-dom/client");
  const { EffortTrack } = await import("../src/agent-session/acpmux/EffortTrack");
  const { reasoningChoices } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const options = ["low", "medium", "high", "max"].map((value) => ({ value }));
  const efforts = reasoningChoices(
    options,
    { efforts: ["low", "medium", "high", "max"], defaultEffort: "high" },
    (key) => translate(key),
  );
  root = createRoot(host);
  const draw = (current: string) =>
    act(() => root!.render(<EffortTrack efforts={efforts} current={current} onPick={() => {}} />));

  draw("medium");
  // The compact track intentionally omits redundant visible captions; the native range carries
  // the complete accessible name and current/recommended value instead.
  expect(text(".acpmux-effort-faster")).toBeNull();
  expect(text(".acpmux-effort-smarter")).toBeNull();
  expect(text(".acpmux-effort-recommended")).toBeNull();
  const input = host.querySelector<HTMLInputElement>("input")!;
  expect(input.getAttribute("aria-label")).toBe("Effort");
  expect(input.min).toBe("0");
  expect(input.max).toBe(String(efforts.length - 1));
  expect(input.step).toBe("1");
  expect(input.getAttribute("aria-valuetext")).toBe("Medium");
  draw("high");
  expect(host.querySelector<HTMLInputElement>("input")?.getAttribute("aria-valuetext")).toBe("High, recommended");

  // A model with no known default marks none.
  const plain = reasoningChoices(options, undefined, (key) => translate(key));
  act(() => root!.render(<EffortTrack efforts={plain} current="high" onPick={() => {}} />));
  expect(text(".acpmux-effort-recommended")).toBeNull();
});
