// The composer's actions width (composerScrollLane.ts followActionsWidth) is measured when the
// actions element comes or changes size, never on the composer's own re-render: the composer renders
// on every key, and a layout read there forced each key's layout before its frame (CMUX-571
// typing-latency, composer-typing bench --profile).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "HTMLElement", "Node", "Element", "MutationObserver", "ResizeObserver"];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
const resized: (() => void)[] = [];

beforeAll(() => {
  dom = new JSDOM("<!doctype html><body></body>", { url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    ResizeObserver: class {
      constructor(callback: () => void) {
        resized.push(callback);
      }
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a re-render beside the prompt reads no layout; a cleared width and new actions are measured", async () => {
  const { followActionsWidth } = await import("../src/agent-session/acpmux/composerScrollLane");
  document.body.innerHTML = `<div class="acpmux-composer-box"><div class="acpmux-md-field"></div>
    <div class="acpmux-chrome-area"><div class="acpmux-composer-actions"></div><span class="ring"></span></div></div>`;
  const box = document.querySelector<HTMLElement>(".acpmux-composer-box")!;
  const field = document.querySelector<HTMLElement>(".acpmux-md-field")!;
  let reads = 0;
  let width = 64;
  const measuredBy = (element: HTMLElement) =>
    (element.getBoundingClientRect = () => {
      reads += 1;
      return { width } as DOMRect;
    });
  measuredBy(document.querySelector<HTMLElement>(".acpmux-composer-actions")!);
  const stop = followActionsWidth(field)!;
  expect(box.style.getPropertyValue("--acpmux-actions-width")).toBe("64px");
  reads = 0;

  // What a key's re-render does beside the prompt: a style written outside the field.
  for (let key = 0; key < 20; key++) {
    document.querySelector<HTMLElement>(".ring")!.style.setProperty("--fill", `${key}%`);
    await settle();
  }
  expect(reads).toBe(0);

  // The actions grew: the resize observer measures.
  width = 96;
  resized.at(-1)!();
  expect(box.style.getPropertyValue("--acpmux-actions-width")).toBe("96px");

  // A write that cleared the box's width puts it back.
  reads = 0;
  box.style.removeProperty("--acpmux-actions-width");
  await settle();
  expect(box.style.getPropertyValue("--acpmux-actions-width")).toBe("96px");
  expect(reads).toBe(1);

  // New actions are measured.
  const next = document.createElement("div");
  next.className = "acpmux-composer-actions";
  width = 40;
  measuredBy(next);
  document.querySelector(".acpmux-composer-actions")!.replaceWith(next);
  await settle();
  expect(box.style.getPropertyValue("--acpmux-actions-width")).toBe("40px");
  stop();
});
