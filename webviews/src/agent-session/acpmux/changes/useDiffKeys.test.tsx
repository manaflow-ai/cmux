import { afterEach, expect, test } from "bun:test";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useDiffKeys } from "./useDiffKeys";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = ["window", "document", "Node", "Element", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    Element: dom.window.Element,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const rect = (top: number, bottom: number) => () =>
  ({ top, bottom, left: 0, right: 0, width: 0, height: bottom - top }) as DOMRect;

function Panel({ selected }: { selected?: string }) {
  const panel = useRef<HTMLDivElement>(null);
  const body = useRef<HTMLDivElement>(null);
  useDiffKeys(
    panel,
    body,
    () => {},
    () => selected,
  );
  return (
    <div ref={panel} id="panel">
      <div ref={body} id="body">
        <section className="acpmux-diff-file" data-path="a.ts">
          <button type="button" data-viewed-toggle="" id="viewed-a" aria-label="Viewed a" />
        </section>
        <section className="acpmux-diff-file" data-path="a.ts" id="a-second-edit">
          <button type="button" data-viewed-toggle="" id="viewed-a2" aria-label="Viewed a2" />
        </section>
        <section className="acpmux-diff-file" data-path="b.ts">
          <button type="button" data-viewed-toggle="" id="viewed-b" aria-label="Viewed b" />
        </section>
      </div>
    </div>
  );
}

function setup(selected?: string) {
  const host = installDom();
  root = createRoot(host);
  act(() => root!.render(<Panel selected={selected} />));
  const document = host.ownerDocument;
  const body = document.getElementById("body")!;
  Object.defineProperty(body, "clientHeight", { value: 100 });
  body.getBoundingClientRect = rect(0, 100);
  // File a is scrolled above the view, b is showing.
  document.querySelector<HTMLElement>('[data-path="a.ts"]')!.getBoundingClientRect = rect(-200, -10);
  document.querySelector<HTMLElement>('[data-path="b.ts"]')!.getBoundingClientRect = rect(20, 80);
  document.getElementById("a-second-edit")!.getBoundingClientRect = rect(500, 600);
  const clicks: string[] = [];
  for (const id of ["viewed-a", "viewed-a2", "viewed-b"])
    document.getElementById(id)!.addEventListener("click", () => clicks.push(id));
  return { document, clicks };
}

const press = (document: Document, key: string, init: KeyboardEventInit = {}) => {
  const event = new (document.defaultView as unknown as typeof globalThis).KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true,
    ...init,
  });
  act(() => {
    document.getElementById("panel")!.dispatchEvent(event);
  });
  return event;
};

test("v marks the first file in view viewed", () => {
  const { document, clicks } = setup();
  const event = press(document, "v");
  expect(clicks).toEqual(["viewed-b"]);
  expect(event.defaultPrevented).toBe(true);
});

test("v follows the picked file when it is not the first one in view", () => {
  // Both files show; without the pick, the first in view (a) would be the target.
  const { document, clicks } = setup("b.ts");
  document.querySelector<HTMLElement>('[data-path="a.ts"]')!.getBoundingClientRect = rect(0, 40);
  press(document, "v");
  expect(clicks).toEqual(["viewed-b"]);
});

test("v follows a picked first file, and falls back to the first in view when the pick scrolled out", () => {
  const { document, clicks } = setup("a.ts");
  document.querySelector<HTMLElement>('[data-path="a.ts"]')!.getBoundingClientRect = rect(0, 40);
  press(document, "v");
  expect(clicks).toEqual(["viewed-a"]);
  // The pick scrolls away: the first file still in view is the target instead.
  document.querySelector<HTMLElement>('[data-path="a.ts"]')!.getBoundingClientRect = rect(-200, -10);
  press(document, "v");
  expect(clicks).toEqual(["viewed-a", "viewed-b"]);
});

test("v finds a file whose later edit shows although its first edit scrolled away", () => {
  const { document, clicks } = setup("a.ts");
  document.getElementById("a-second-edit")!.getBoundingClientRect = rect(10, 60);
  document.querySelector<HTMLElement>('[data-path="b.ts"]')!.getBoundingClientRect = rect(70, 95);
  press(document, "v");
  expect(clicks).toEqual(["viewed-a2"]);
});

test("a modified v is left to the app", () => {
  const { document, clicks } = setup();
  press(document, "v", { metaKey: true });
  expect(clicks).toEqual([]);
});
