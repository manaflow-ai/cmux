// Generic Picker rows must not execute actions on context-menu or auxiliary mouse presses.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

async function fixture(keep = false) {
  const { createRoot } = await import("react-dom/client");
  const { Picker } = await import("../src/agent-session/acpmux/ComposerPickers");
  const calls: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <Picker
        label="Actions"
        className="acpmux-composer-plus"
        button="Actions"
        align="start"
        sections={[
          {
            choices: [
              { id: "first", name: "First" },
              { id: "second", name: "Second" },
            ],
            onPick: (id) => {
              calls.push(id);
              return keep ? "keep" : undefined;
            },
          },
        ]}
      />,
    ),
  );
  const trigger = host.querySelector<HTMLButtonElement>("button")!;
  await act(async () => trigger.click());
  const row = host.querySelector<HTMLElement>('[data-value="second"]')!;
  return { calls, trigger, row };
}

for (const button of [1, 2]) {
  test(`button ${button} does not select and keeps the keyboard on the trigger`, async () => {
    const { calls, trigger, row } = await fixture();
    const press = new dom.window.MouseEvent("mousedown", {
      bubbles: true,
      cancelable: true,
      button,
    });
    await act(async () => row.dispatchEvent(press));
    expect(calls).toEqual([]);
    expect(press.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(trigger);
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
  });
}

test("primary press selects once, retains focus and closes", async () => {
  const { calls, trigger, row } = await fixture();
  const press = new dom.window.MouseEvent("mousedown", {
    bubbles: true,
    cancelable: true,
    button: 0,
  });
  await act(async () => row.dispatchEvent(press));
  expect(press.defaultPrevented).toBe(true);
  expect(calls).toEqual(["second"]);
  expect(trigger.getAttribute("aria-expanded")).toBe("false");
  expect(document.activeElement).toBe(trigger);
});

test("keep-open rows still select on a primary press", async () => {
  const { calls, trigger, row } = await fixture(true);
  await act(async () =>
    row.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 })),
  );
  expect(calls).toEqual(["second"]);
  expect(trigger.getAttribute("aria-expanded")).toBe("true");
});

for (const key of ["Enter", " "]) {
  test(`arrows and ${key === " " ? "Space" : key} still select from the trigger`, async () => {
    const { calls, trigger } = await fixture();
    await act(async () =>
      trigger.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", {
          key: "ArrowDown",
          bubbles: true,
          cancelable: true,
        }),
      ),
    );
    for (const type of ["keydown", "keyup"]) {
      await act(async () =>
        trigger.dispatchEvent(
          new dom.window.KeyboardEvent(type, { key, bubbles: true, cancelable: true }),
        ),
      );
    }
    expect(calls).toEqual(["second"]);
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
  });
}
