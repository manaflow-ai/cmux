// A hover card ends with no pointer event on its trigger or card (Lucas, 2026-11-11: an image's
// card stayed on screen with the pointer no longer on it): a pointer that leaves the page or a
// window that loses focus sends no leave. A scroll is ui/scrollHover.ts's (#40035).
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useHoverCard } from "./useHoverCard";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

function Card() {
  const hover = useHoverCard(0);
  return (
    <>
      <button type="button" className="trigger" {...hover.trigger}>
        image
      </button>
      {hover.open && (
        <div className="ui-tooltip">
          <div className="card" {...hover.card}>
            big image
          </div>
        </div>
      )}
    </>
  );
}

async function render(): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(<Card />);
  });
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/// Opens the card at once, as keyboard focus does.
async function opened(container: HTMLElement) {
  const trigger = container.querySelector<HTMLButtonElement>(".trigger")!;
  await act(async () => trigger.blur());
  await act(async () => trigger.focus());
  expect(container.querySelector(".card")).not.toBeNull();
}

test("a pointer that leaves the page, or a window that loses focus, closes it", async () => {
  const container = await render();
  await opened(container);
  await act(async () => {
    dom!.window.document.body.dispatchEvent(new dom!.window.MouseEvent("pointerout", { relatedTarget: null }));
  });
  expect(container.querySelector(".card")).toBeNull();
  await opened(container);
  await act(async () => {
    dom!.window.dispatchEvent(new dom!.window.Event("blur"));
  });
  expect(container.querySelector(".card")).toBeNull();
});

test("a pointer that leaves the page keeps a card the keyboard is in", async () => {
  const container = await render();
  await opened(container);
  const inside = dom!.window.document.createElement("button");
  container.querySelector(".card")!.append(inside);
  await act(async () => inside.focus());
  await act(async () => {
    dom!.window.document.body.dispatchEvent(new dom!.window.MouseEvent("pointerout", { relatedTarget: null }));
  });
  expect(container.querySelector(".card")).not.toBeNull();
});
