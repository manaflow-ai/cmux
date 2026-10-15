// The New Tab page chooses its style (Leo 2026-10-13: the old template dots looked, clicked and
// moved badly, but choosing the style was good; 10-14: the dots again, #20473, and every look he
// compared is an opt-in Debug Settings look). The switch draws one of five looks (Debug Settings
// `newTab.styleSwitch`, sent as `styleSwitch`): round dots that name the one pointed at (the default),
// the chip dots that name a pick for a moment, those dots as they were before #20127, a strip of
// small layout glyphs, or #20336's names. Every look is the same native radio group: arrow keys move
// between the styles, a pick is saved as `tabs.newTabTemplate` (`newTab.setTemplate`) and shown in
// place, a pointer pick hands focus back to the field. Terminal is not offered: New Tab never opens
// a terminal by itself.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
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
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div><input id=field>", { pretendToBeVisual: true }).window;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    HTMLInputElement: window.HTMLInputElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  // Focus moves queue jsdom selectionchange events; closing the window drops them before the
  // globals they reach go.
  window.close();
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
      () =>
        act(async () => {
          for (const callback of frames.splice(0)) callback(window.performance.now());
        }),
      () =>
        act(async () => {
          for (const callback of timers.splice(0)) callback();
        }),
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
    expect(
      radios()
        .filter((radio) => radio.checked)
        .map((radio) => radio.value),
    ).toEqual(["default"]);
    const titles = () => [...host.querySelectorAll("label")].map((label) => label.title);
    if (look === "names") {
      expect(host.textContent).toContain("Composer");
    } else if (look === "round") {
      // Round names a dot over it while pointed at, so no tooltip and no name at rest.
      expect(host.textContent).toBe("");
      expect(titles()).toEqual(["", "", "", "", ""]);
    } else {
      // At rest the style names are tooltips (the page's instant `title` tooltips), not text.
      expect(host.textContent).toBe("");
      expect(titles()).toEqual(["Default", "Composer", "Threads", "Console", "Classic"]);
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
      // The dots that name a pick show its name over them for a moment.
      const flash = () => host.querySelector(".nt-style-flash")?.textContent ?? "";
      expect(flash()).toBe(look === "hint" ? "Threads" : "");
      // Round names the pick over its dot for a moment.
      const named = () => host.querySelector(".nt-style-name[data-shown]")?.textContent ?? "";
      expect(named()).toBe(look === "round" ? "Threads" : "");
      await wait();
      expect(flash()).toBe("");
      expect(named()).toBe("");

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

test("round dots are the look with nothing set", () => {
  expect(DEFAULT_STYLE_SWITCH).toBe("round");
  expect(newTabHost({ newTab: { layout: "b" } })!.styleSwitch).toBeUndefined();
  expect(newTabHost({ newTab: { layout: "b", styleSwitch: "strip" } })!.styleSwitch).toBe("strip");
  expect(newTabHost({ newTab: { layout: "b", styleSwitch: "sparkles" } })!.styleSwitch).toBeUndefined();
});

test("round: a pointer over a dot names it, over that dot; leaving the row hides the name", async () => {
  const host = window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => root.render(createElement(StyleSwitch, { current: "threads", onPick() {}, onCancel() {} })));
  const name = () => host.querySelector<HTMLElement>(".nt-style-name")!;
  expect(name().hasAttribute("data-shown")).toBe(false);
  const composer = host.querySelector("label[data-style=composer]")!;
  await act(async () => void composer.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true })));
  expect([name().textContent, name().hasAttribute("data-shown")]).toEqual(["Composer", true]);
  await act(async () => void composer.dispatchEvent(new window.MouseEvent("pointerout", { bubbles: true })));
  expect(name().hasAttribute("data-shown")).toBe(false);
  await act(async () => root.unmount());
});

// cg-design-judge: every style showed a browser-default radio dot. The pane does not load
// src/ui/ui.css, so its .ui-sr-only never applied; the page's own stylesheet hides the inputs. Each
// radio fills its option's target, unseen, so a click anywhere on the target picks the style.
test("the style radios draw no native dot in any look: the page's own stylesheet hides them", async () => {
  const style = window.document.createElement("style");
  style.textContent = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/newtab/screen.css"), "utf8");
  window.document.head.append(style);
  const host = window.document.getElementById("root")!;
  const root = createRoot(host);
  for (const look of STYLE_SWITCHES) {
    await act(async () => {
      root.render(createElement(StyleSwitch, { look, current: "default", onPick() {}, onCancel() {} }));
    });
    const radios = [...host.querySelectorAll<HTMLInputElement>("input[type=radio]")];
    expect(radios).toHaveLength(5);
    for (const radio of radios) {
      const drawn = window.getComputedStyle(radio);
      expect([look, radio.value, drawn.position, drawn.width, drawn.height, drawn.opacity]).toEqual([
        look,
        radio.value,
        "absolute",
        "100%",
        "100%",
        "0",
      ]);
    }
  }
  await act(async () => root.unmount());
  style.remove();
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
