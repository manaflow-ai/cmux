// l10n-allow-file: test fixtures.
// The markdown viewer's text width control (user 2026-10-19: "text width to be much more flexible
// ... super super wide ... but not actually full width"; "what if someone wants to type in a value
// instead of using a slider ... how apps like Microsoft Word or Figma will make this look and
// feel"). The field takes typed widths with units and arithmetic, clamps to the range and shows the
// clamped value, steps with Up/Down (Shift for 10), and the label scrubs it sideways.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/** Renders the field as the popover does: its writes go back in as props, as the store does. */
async function render(initial: { width: number; fullWidth?: boolean }) {
  const { createRoot } = await import("react-dom/client");
  const { WidthField } = await import("../src/pages/markdown/WidthField");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const strings = createStrings({ en: {} }, ["en"]);
  const state = { width: initial.width, fullWidth: initial.fullWidth ?? false, writes: [] as number[] };
  const draw = () =>
    root!.render(
      createElement(WidthField, {
        width: state.width,
        fullWidth: state.fullWidth,
        strings,
        characterWidth: () => 8,
        setWidth(width: number) {
          state.writes.push(width);
          state.width = width;
          state.fullWidth = false;
          draw();
        },
        setFullWidth(fullWidth: boolean) {
          state.fullWidth = fullWidth;
          draw();
        },
      }),
    );
  root = createRoot(host);
  act(draw);
  const input = host.querySelector<HTMLInputElement>(".md-width-input")!;
  return { state, input };
}

function type(input: HTMLInputElement, text: string) {
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    input.focus();
    setter.call(input, text);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}

function key(input: HTMLInputElement, name: string, shiftKey = false) {
  act(() => {
    input.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, shiftKey, bubbles: true }));
  });
}

test("a typed number is characters; Return applies it", async () => {
  const { state, input } = await render({ width: 72 });
  expect(input.value).toBe("72");
  type(input, "240");
  expect(state.writes).toEqual([]);
  key(input, "Enter");
  expect(state.writes).toEqual([240]);
  expect(input.value).toBe("240");
});

test("points and arithmetic convert to characters (8px a character here)", async () => {
  const { state, input } = await render({ width: 72 });
  type(input, "1600pt");
  key(input, "Enter");
  type(input, "120ch * 2");
  key(input, "Enter");
  expect(state.writes).toEqual([200, 240]);
});

test("out of range takes the nearest end and the field shows it", async () => {
  const { state, input } = await render({ width: 72 });
  type(input, "50000");
  key(input, "Enter");
  expect(state.width).toBe(1000);
  expect(input.value).toBe("1000");
  type(input, "3");
  key(input, "Enter");
  expect(input.value).toBe("30");
});

test("text that is not a width keeps the value and marks the field", async () => {
  const { state, input } = await render({ width: 90 });
  type(input, "wide please");
  key(input, "Enter");
  expect(state.writes).toEqual([]);
  expect(input.value).toBe("90");
  expect(input.getAttribute("aria-invalid")).toBe("true");
});

test("Escape puts the value back without writing", async () => {
  const { state, input } = await render({ width: 90 });
  type(input, "400");
  key(input, "Escape");
  expect(input.value).toBe("90");
  expect(state.writes).toEqual([]);
});

test("Up and Down step by 1, Shift by 10, inside the range", async () => {
  const { state, input } = await render({ width: 100 });
  key(input, "ArrowUp");
  key(input, "ArrowUp", true);
  key(input, "ArrowDown");
  expect(state.writes).toEqual([101, 111, 110]);
  const low = await (async () => {
    act(() => root?.unmount());
    host.replaceChildren();
    return render({ width: 30 });
  })();
  key(low.input, "ArrowDown", true);
  expect(low.state.width).toBe(30);
});

test("dragging the label scrubs the width; a width leaves full width", async () => {
  const { state } = await render({ width: 100, fullWidth: true });
  const label = host.querySelector<HTMLElement>(".md-width-scrub")!;
  const pointer = (type: string, clientX: number) =>
    act(() => {
      label.dispatchEvent(new dom.window.MouseEvent(type, { clientX, button: 0, bubbles: true, cancelable: true }));
    });
  pointer("pointerdown", 200);
  pointer("pointermove", 240);
  pointer("pointerup", 240);
  expect(state.width).toBe(120);
  expect(state.fullWidth).toBe(false);
});
