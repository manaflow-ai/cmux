// The New Tab page chooses its style again (Leo 2026-10-13: the old template dots looked, clicked
// and moved badly, but choosing the style was good). One quiet row of the five page styles: native
// radios (arrow keys move between them), the current one marked, a pick saved as
// `tabs.newTabTemplate` (`newTab.setTemplate`) and shown in place. Terminal is not offered: New Tab
// never opens a terminal by itself.
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

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
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

test("the New Tab page offers its five styles as radios, the current one checked", async () => {
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
  // The names show as text, not as dots with tooltips.
  expect(host.textContent).toContain("Composer");

  // A click goes back to the field once the picked page has mounted (the frame after the pick).
  let fieldAsked = 0;
  window.addEventListener("acpmux-focus-location", () => fieldAsked++);
  await act(async () => {
    radios[4]!.dispatchEvent(new window.Event("pointerdown", { bubbles: true }));
    radios[4]!.click();
  });
  expect(picks).toEqual(["classic"]);
  expect(fieldAsked).toBe(0);
  await act(() => new Promise<void>((done) => window.requestAnimationFrame(() => done())));
  await act(() => new Promise<void>((done) => window.requestAnimationFrame(() => done())));
  expect(fieldAsked).toBe(1);
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
