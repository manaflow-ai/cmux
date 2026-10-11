import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { syntheticKey } from "../src/gallery/frame/playRunner";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "KeyboardEvent",
  "getComputedStyle",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

describe("gallery shell keyboard emulation", () => {
  test("moves focus through tabbable controls in both directions", () => {
    document.getElementById("root")!.innerHTML = `
      <button id="before">Before</button>
      <button id="disabled" disabled>Disabled</button>
      <button id="first">First</button>
      <button id="hidden" hidden>Hidden</button>
      <button id="second">Second</button>
    `;
    const first = document.getElementById("first") as HTMLButtonElement;
    const second = document.getElementById("second") as HTMLButtonElement;
    first.focus();

    syntheticKey("Tab");
    expect(document.activeElement).toBe(second);
    syntheticKey("Shift+Tab");
    expect(document.activeElement).toBe(first);
  });

  test("leaves focus to a key handler that prevents the default", () => {
    document.getElementById("root")!.innerHTML = '<button id="first">First</button><button id="second">Second</button>';
    const first = document.getElementById("first") as HTMLButtonElement;
    const second = document.getElementById("second") as HTMLButtonElement;
    first.addEventListener("keydown", (event) => event.preventDefault());
    first.focus();

    syntheticKey("Tab");
    expect(document.activeElement).toBe(first);
    expect(document.activeElement).not.toBe(second);
  });
});
