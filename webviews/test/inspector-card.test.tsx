import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { InspectorCard } from "../src/agent-session/acpmux/inspector/InspectorCard";
import {
  DEFAULT_INSPECTOR_ORDER,
  moveSection,
  type InspectorOrderId,
} from "../src/agent-session/acpmux/inspector/sectionOrder";

const dom = new JSDOM("<!doctype html><html><body /></html>", { url: "http://localhost/" });
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
});

function dragData() {
  const values = new Map<string, string>();
  return {
    effectAllowed: "",
    types: ["application/x-cmux-inspector-section"],
    setData: (key: string, value: string) => values.set(key, value),
    getData: (key: string) => values.get(key) ?? "",
  } as unknown as DataTransfer;
}

function mount(
  onMove: (id: InspectorOrderId, target: InspectorOrderId, after?: boolean) => void,
  order: readonly InspectorOrderId[] = DEFAULT_INSPECTOR_ORDER,
) {
  const container = document.createElement("main");
  document.body.append(container);
  const root = createRoot(container);
  act(() => {
    root.render(
      <InspectorCard id="changes" order={order} onMove={onMove}>
        <div data-testid="body">Changes</div>
      </InspectorCard>,
    );
  });
  return { container, root };
}

test("keyboard reordering skips sections omitted from the visible cards", async () => {
  const moves: unknown[] = [];
  const { container } = mount((...move) => moves.push(move), ["changes", "context"]);
  const handle = container.querySelector<HTMLButtonElement>(".acpmux-chat-inspector-card__handle")!;
  await act(async () =>
    handle.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })),
  );
  expect(moves).toEqual([["changes", "context", true]]);
});

test("card handle uses ArrowUp/ArrowDown without toggling its section", async () => {
  const moves: unknown[] = [];
  const { container } = mount((...move) => moves.push(move));
  const handle = container.querySelector<HTMLButtonElement>(".acpmux-chat-inspector-card__handle")!;
  await act(async () =>
    handle.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true })),
  );
  expect(moves).toEqual([["changes", "connectors", false]]);
  expect(container.querySelector("[data-testid=body]")?.textContent).toBe("Changes");
});

test("dragging the handle drops Changes before Context", async () => {
  const moves: unknown[] = [];
  const container = document.createElement("main");
  document.body.append(container);
  const root = createRoot(container);
  act(() => {
    function SortableCards() {
      const [order, setOrder] = useState<readonly InspectorOrderId[]>(DEFAULT_INSPECTOR_ORDER);
      const onMove = (id: InspectorOrderId, target: InspectorOrderId, after?: boolean) => {
        moves.push([id, target, after]);
        setOrder(moveSection(order, id, target, after));
      };
      return (
        <>
          {order.map((id) => (
            <InspectorCard key={id} id={id} order={order} onMove={onMove}>
              <div>{id}</div>
            </InspectorCard>
          ))}
        </>
      );
    }
    root.render(<SortableCards />);
  });
  const handle = container.querySelector<HTMLButtonElement>(
    "[data-section-card=changes] .acpmux-chat-inspector-card__handle",
  )!;
  const card = container.querySelector<HTMLElement>("[data-section-card=context]")!;
  const dataTransfer = dragData();
  Object.defineProperty(card, "getBoundingClientRect", { value: () => ({ top: 0, height: 100 }) });
  const dispatch = async (element: Element, type: string, clientY?: number) => {
    const event = new dom.window.Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(event, "dataTransfer", { value: dataTransfer });
    if (clientY !== undefined) Object.defineProperty(event, "clientY", { value: clientY });
    await act(async () => element.dispatchEvent(event));
  };
  await dispatch(handle, "dragstart");
  await dispatch(card, "dragover", 1);
  expect(card.getAttribute("data-drop")).toBe("before");
  await dispatch(card, "dragleave");
  expect(card.hasAttribute("data-drop")).toBe(false);
  await dispatch(card, "dragover", 1);
  await dispatch(card, "drop", 1);
  expect(moves).toEqual([["changes", "context", false]]);
  const ids = [...container.querySelectorAll<HTMLElement>("[data-section-card]")].map(
    (card) => card.dataset.sectionCard,
  );
  expect(ids.indexOf("changes")).toBeLessThan(ids.indexOf("context"));
  root.unmount();
});
