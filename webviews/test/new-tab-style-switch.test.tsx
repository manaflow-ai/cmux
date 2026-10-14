// The New Tab page chooses its style (Leo 2026-10-13: the old template dots looked, clicked and
// moved badly, but choosing the style was good; 10-14: he wants to see the dots again before the
// names of #20336 replace them). The switch draws one of four looks (Debug Settings
// `newTab.styleSwitch`, sent as `styleSwitch`): the dots as they were before #20127, the dots that
// name a pick for a moment (the default), a strip of small layout glyphs, or #20336's names. Every
// look is the same native radio group: arrow keys move between the styles, a pick is saved as
// `tabs.newTabTemplate` (`newTab.setTemplate`) and shown in place, a pointer pick hands focus back
// to the field. Terminal is not offered: New Tab never opens a terminal by itself.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement, useState } from "react";
import { createRoot } from "react-dom/client";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";
import { StyleSwitch } from "../src/agent-session/acpmux/newtab/StyleSwitch";
import {
  DEFAULT_STYLE_SWITCH,
  STYLE_SWITCHES,
  pickNewTabStyle,
  type PageStyle,
  type StyleSwitchLook,
} from "../src/agent-session/acpmux/newtab/templates";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div><input id=field>", { pretendToBeVisual: true }).window;
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

/// The page's wiring (App.tsx): a pick goes through pickNewTabStyle and shows in place.
function Page({ look, sent }: { look: StyleSwitchLook; sent: [string, unknown][] }) {
  const [current, setCurrent] = useState<PageStyle>("default");
  return createElement(StyleSwitch, {
    look,
    current,
    onCancel: () => window.dispatchEvent(new window.Event("acpmux-focus-location")),
    onPick: (style: PageStyle) =>
      pickNewTabStyle(style, {
        callNative: async (method, params) => void sent.push([method, params]),
        show: setCurrent,
      }),
  });
}

/// Runs the switch's frames and timers by hand: jsdom's own are timers a loaded runner can reach
/// before the first check, or after the last.
async function withClock(run: (tick: () => Promise<void>, wait: () => Promise<void>) => Promise<void>) {
  const frames: FrameRequestCallback[] = [];
  const timers: (() => void)[] = [];
  const nextFrame = window.requestAnimationFrame;
  const setTimer = window.setTimeout;
  window.requestAnimationFrame = (callback) => frames.push(callback);
  window.setTimeout = ((callback: () => void) => timers.push(callback)) as typeof window.setTimeout;
  try {
    await run(
      () => act(async () => void frames.splice(0).forEach((callback) => callback(window.performance.now()))),
      () => act(async () => void timers.splice(0).forEach((callback) => callback())),
    );
  } finally {
    window.requestAnimationFrame = nextFrame;
    window.setTimeout = setTimer;
  }
}

for (const look of STYLE_SWITCHES) {
  test(`${look}: the five styles are one radio group; a pick is saved, a click goes back to the field`, async () => {
    const host = window.document.getElementById("root")!;
    const root = createRoot(host);
    const sent: [string, unknown][] = [];
    await act(async () => root.render(createElement(Page, { look, sent })));

    const group = host.querySelector("fieldset")!;
    expect(group.getAttribute("aria-label")).toBe("New Tab templates");
    expect(host.querySelector<HTMLElement>(".nt-style-options")!.dataset.look).toBe(look);
    const radios = () => [...host.querySelectorAll<HTMLInputElement>("input[type=radio]")];
    expect(radios().map((radio) => radio.value)).toEqual(["default", "composer", "threads", "console", "classic"]);
    expect(radios().map((radio) => radio.getAttribute("aria-label"))).toEqual([
      "Default",
      "Composer",
      "Threads",
      "Console",
      "Classic",
    ]);
    expect(new Set(radios().map((radio) => radio.name)).size).toBe(1);
    expect(radios().filter((radio) => radio.checked).map((radio) => radio.value)).toEqual(["default"]);
    if (look === "names") {
      expect(host.textContent).toContain("Composer");
    } else {
      // At rest the style names are tooltips (the page's instant `title` tooltips), not text.
      expect(host.textContent).toBe("");
      expect([...host.querySelectorAll("label")].map((label) => label.title)).toEqual([
        "Default",
        "Composer",
        "Threads",
        "Console",
        "Classic",
      ]);
    }

    let fieldAsked = 0;
    const asked = () => fieldAsked++;
    window.addEventListener("acpmux-focus-location", asked);
    await withClock(async (tick, wait) => {
      // A pointer pick: saved, shown, and the field asked for once the picked page has mounted.
      await act(async () => {
        radios()[2]!.dispatchEvent(new window.Event("pointerdown", { bubbles: true }));
        radios()[2]!.click();
      });
      expect(sent).toEqual([["newTab.setTemplate", { template: "threads" }]]);
      expect(radios().find((radio) => radio.checked)?.value).toBe("threads");
      expect(fieldAsked).toBe(0);
      await tick();
      expect(fieldAsked).toBe(1);
      // The dots that name a pick show its name under them for a moment.
      const flash = () => host.querySelector(".nt-style-flash")?.textContent ?? "";
      expect(flash()).toBe(look === "hint" ? "Threads" : "");
      await wait();
      expect(flash()).toBe("");

      // A keyboard pick (an arrow key checks the next radio, with no pointer down): saved, and
      // focus stays on the switch to keep moving, even when the picked page focused its field.
      radios()[3]!.focus();
      await act(async () => radios()[3]!.click());
      expect(sent.at(-1)).toEqual(["newTab.setTemplate", { template: "console" }]);
      window.document.getElementById("field")!.focus();
      await tick();
      expect(window.document.activeElement).toBe(radios()[3]!);
      expect(fieldAsked).toBe(1);

      // Return and Escape go back to the field.
      for (const key of ["Escape", "Enter"]) {
        await act(
          async () => void radios()[3]!.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true })),
        );
      }
      expect(fieldAsked).toBe(3);
    });
    window.removeEventListener("acpmux-focus-location", asked);
    await act(async () => root.unmount());
  });
}

test("the dots that name a pick are the look with no knob set", () => {
  expect(DEFAULT_STYLE_SWITCH).toBe("hint");
  expect(newTabHost({ newTab: { layout: "b" } })!.styleSwitch).toBeUndefined();
  expect(newTabHost({ newTab: { layout: "b", styleSwitch: "strip" } })!.styleSwitch).toBe("strip");
  expect(newTabHost({ newTab: { layout: "b", styleSwitch: "sparkles" } })!.styleSwitch).toBeUndefined();
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
