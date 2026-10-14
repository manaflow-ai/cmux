// The New Tab page chooses its style with dots (Leo 2026-10-14: "what happened to the dots at the
// bottom, why's there text"). One dot per page style: native radios (arrow keys move between them),
// named for screen readers; a pointer over a dot shows its name, a pick shows the picked name for a
// moment and then fades it; a pick is saved as `tabs.newTabTemplate` (`newTab.setTemplate`) and
// shown in place. Terminal is not offered: New Tab never opens a terminal by itself.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { StyleSwitch } from "../src/agent-session/acpmux/newtab/StyleSwitch";
import { pickNewTabStyle } from "../src/agent-session/acpmux/newtab/templates";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
// Frames run only when the test runs them: JSDOM's own are a 16 ms timer, which on a loaded runner
// fired the pick's frame inside the click's act() (as in #20431).
const frames = new Map<number, FrameRequestCallback>();
let lastFrame = 0;
const nextFrame = () => {
  const due = [...frames.values()];
  frames.clear();
  for (const run of due) run(0);
};

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.assign(window, {
    requestAnimationFrame: (run: FrameRequestCallback) => (frames.set(++lastFrame, run), lastFrame),
    cancelAnimationFrame: (id: number) => frames.delete(id),
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the New Tab page offers its five styles as named dots, the current one checked", async () => {
  const host = window.document.getElementById("root")!;
  const root = createRoot(host);
  const picks: string[] = [];
  await act(async () => {
    root.render(
      createElement(StyleSwitch, { current: "threads", onPick: (style) => picks.push(style), onCancel() {} }),
    );
  });
  const group = host.querySelector("fieldset")!;
  expect(group.getAttribute("aria-label")).toBe("New Tab templates");
  const radios = [...host.querySelectorAll<HTMLInputElement>("input[type=radio]")];
  expect(radios.map((radio) => radio.value)).toEqual(["default", "composer", "threads", "console", "classic"]);
  expect(radios.map((radio) => radio.getAttribute("aria-label"))).toEqual([
    "Default",
    "Composer",
    "Threads",
    "Console",
    "Classic",
  ]);
  expect(radios.filter((radio) => radio.checked).map((radio) => radio.value)).toEqual(["threads"]);
  // Dots: no name shows at rest.
  const name = () => host.querySelector<HTMLElement>(".nt-style-name")!;
  expect(name().hasAttribute("data-shown")).toBe(false);
  // A pointer over a dot shows its name, over that dot; leaving the row hides it.
  await act(async () => {
    radios[1]!.closest("label")!.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
  });
  expect(name().textContent).toBe("Composer");
  expect(name().hasAttribute("data-shown")).toBe(true);
  await act(async () => {
    radios[1]!.closest("label")!.dispatchEvent(new window.MouseEvent("pointerout", { bubbles: true }));
  });
  expect(name().hasAttribute("data-shown")).toBe(false);

  // A click goes back to the field once the picked page has mounted (the frame after the pick).
  let fieldAsked = 0;
  window.addEventListener("acpmux-focus-location", () => fieldAsked++);
  await act(async () => {
    radios[4]!.dispatchEvent(new window.Event("pointerdown", { bubbles: true }));
    radios[4]!.click();
  });
  expect(picks).toEqual(["classic"]);
  expect(fieldAsked).toBe(0);
  await act(async () => nextFrame());
  expect(fieldAsked).toBe(1);
  // The pick shows its name for a moment, then lets it fade.
  expect(name().textContent).toBe("Classic");
  expect(name().hasAttribute("data-shown")).toBe(true);
  await act(() => new Promise<void>((done) => setTimeout(done, 1600)));
  expect(name().hasAttribute("data-shown")).toBe(false);
  await act(async () => root.unmount());
});

test("a style picked on the page is saved as tabs.newTabTemplate and shown in place", () => {
  const sent: [string, unknown][] = [];
  const shown: string[] = [];
  pickNewTabStyle("console", {
    callNative: async (method, params) => void sent.push([method, params]),
    show: (style) => shown.push(style),
  });
  expect(sent).toEqual([["newTab.setTemplate", { template: "console" }]]);
  expect(shown).toEqual(["console"]);
});
