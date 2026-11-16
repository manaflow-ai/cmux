// The New Tab clock (`tabs.newTabClock.*`): the handshake's look, the Lock Screen time text, and one
// timer to the next minute that ends with the page.
import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../../test/support/domTeardown";
import { newTabHost } from "../newTabModel";
import { clockTime, msToNextMinute, readClockStyle } from "./clockModel";
import { NewTabClock } from "./NewTabClock";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});

test("no clock unless the host sends one; a look the page does not know reads as the default", () => {
  expect(newTabHost({ newTab: {} })?.clock).toBeUndefined();
  expect(newTabHost({ newTab: { clock: null } })?.clock).toBeUndefined();
  expect(newTabHost({ newTab: { clock: { font: "serif", weight: "thin", color: "glass", date: false } } })?.clock).toEqual({
    font: "serif",
    weight: "thin",
    color: "glass",
    date: false,
  });
  expect(readClockStyle({ font: "comic", weight: 7 })).toEqual({
    font: "rounded",
    weight: "bold",
    color: "text",
    date: true,
  });
});

test("the time drops the AM/PM mark and keeps the locale's hours", () => {
  const at = new Date(2026, 10, 16, 21, 41);
  expect(clockTime(at, "en-US")).toBe("9:41");
  expect(clockTime(at, "en-GB")).toBe("21:41");
});

test("it redraws on the minute, never later", () => {
  expect(msToNextMinute(0)).toBe(60_000);
  expect(msToNextMinute(59_999)).toBe(1);
  expect(msToNextMinute(61_000)).toBe(59_000);
});

test("the clock draws its date and time, and stops its timer with the page", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const at = new Date(2026, 10, 16, 9, 41).getTime();
  await act(async () =>
    root.render(<NewTabClock font="rounded" weight="bold" color="text" date now={at} locale="en-US" />),
  );
  const clock = container.querySelector<HTMLElement>(".nt-clock")!;
  expect(clock.dataset.font).toBe("rounded");
  expect(container.querySelector(".nt-clock-time")?.textContent).toBe("9:41");
  expect(container.querySelector(".nt-clock-date")?.textContent).toBe("Monday, November 16");
  await act(async () =>
    root.render(<NewTabClock font="mono" weight="thin" color="muted" date={false} now={at} locale="en-US" />),
  );
  expect(container.querySelector(".nt-clock-date")).toBeNull();
  await act(async () => root.unmount());
});
