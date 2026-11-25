import { afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { reportInputReadyWhenFocused } from "./inputReady";

let dom: JSDOM;
let focused = false;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
  focused = false;
  Object.defineProperty(dom.window.document, "hasFocus", { configurable: true, value: () => focused });
});

afterEach(() => dom.window.close());

const view = () => dom.window as unknown as Window;
const nextTask = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a focused page reports at once", () => {
  focused = true;
  let reports = 0;
  reportInputReadyWhenFocused(view(), () => reports++);
  expect(reports).toBe(1);
});

test("a page without focus reports at its window's focus, once", () => {
  let reports = 0;
  reportInputReadyWhenFocused(view(), () => reports++, 60_000);
  expect(reports).toBe(0);
  focused = true;
  dom.window.dispatchEvent(new dom.window.FocusEvent("focus"));
  dom.window.dispatchEvent(new dom.window.FocusEvent("focus"));
  expect(reports).toBe(1);
});

test("a page that never gets focus still reports after the wait", async () => {
  let reports = 0;
  reportInputReadyWhenFocused(view(), () => reports++, 0);
  expect(reports).toBe(0);
  await nextTask();
  expect(reports).toBe(1);
  dom.window.dispatchEvent(new dom.window.FocusEvent("focus"));
  expect(reports).toBe(1);
});

test("a cancelled wait never reports", async () => {
  let reports = 0;
  const cancel = reportInputReadyWhenFocused(view(), () => reports++, 0);
  cancel();
  dom.window.dispatchEvent(new dom.window.FocusEvent("focus"));
  await nextTask();
  expect(reports).toBe(0);
});
