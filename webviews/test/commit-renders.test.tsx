// l10n-allow-file: test rows, not shipped UI.
// The row render counter (support/commitRenders.ts) in the default suite: test/preload.ts installs
// React's commit hook before react-dom loads, so a jsdom test counts which rows a change rendered
// with nothing added to the rows. A memoized row list renders the one row that changed; a list
// whose rows take a fresh prop each render renders every row, and the counter says so.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createContext, memo, useContext, useState, useSyncExternalStore } from "react";
import type { Root } from "react-dom/client";
import { rowRenders } from "./support/commitRenders";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

type Item = { id: string; text: string };
const Row = memo(function Row({ item, mark }: { item: Item; mark: { on: boolean } }) {
  return (
    <li className="row" data-on={mark.on || undefined}>
      {item.text}
    </li>
  );
});
const ON = { on: false };
/// `fresh`: every row gets a new `mark` object each render, which defeats its memo.
function List({ items, fresh }: { items: readonly Item[]; fresh: boolean }) {
  return (
    <ul>
      {items.map((item) => (
        <Row key={item.id} item={item} mark={fresh ? { on: false } : ON} />
      ))}
    </ul>
  );
}
const items = Array.from({ length: 50 }, (_, index) => ({ id: `i${index}`, text: `Item ${index}` }));
const changed = items.map((item, index) => (index === 7 ? { ...item, text: "Item 7 (edited)" } : item));

test("one changed item renders its own row only, when the rows are memoized", async () => {
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  act(() => root!.render(<List items={items} fresh={false} />));
  const renders = rowRenders();
  renders.begin(host, ".row");
  act(() => root!.render(<List items={changed} fresh={false} />));
  expect(renders.end()).toEqual({ rerendered: 1, wasted: 0, added: 0, maxRenders: 1 });
});

test("a fresh prop per row renders every row, 49 of them for nothing", () => {
  act(() => root!.render(<List items={items} fresh />));
  const renders = rowRenders();
  renders.begin(host, ".row");
  act(() => root!.render(<List items={changed} fresh />));
  expect(renders.end()).toEqual({ rerendered: 50, wasted: 49, added: 0, maxRenders: 1 });
});

// Canaries: a row that re-renders from its own hooks keeps its props object, so a counter that
// compares props reads 0. The commit hook sees the fiber's work, so each of these must count: one
// state change, one context change and one store tick render every row, all for nothing.
const Theme = createContext(0);
let bump: Array<() => void> = [];
const StateRow = memo(function StateRow({ item }: { item: Item }) {
  const [, setTick] = useState(0);
  bump.push(() => setTick((tick) => tick + 1));
  return <li className="row">{item.text}</li>;
});
const ContextRow = memo(function ContextRow({ item }: { item: Item }) {
  useContext(Theme);
  return <li className="row">{item.text}</li>;
});
let version = 0;
const listeners = new Set<() => void>();
const store = {
  subscribe: (listener: () => void) => (listeners.add(listener), () => listeners.delete(listener)),
  get: () => version,
};
const StoreRow = memo(function StoreRow({ item }: { item: Item }) {
  useSyncExternalStore(store.subscribe, store.get);
  return <li className="row">{item.text}</li>;
});
const few = items.slice(0, 10);

test("a row re-rendered by its own state counts, though its props did not change", () => {
  bump = [];
  act(() =>
    root!.render(
      <ul>
        {few.map((item) => (
          <StateRow key={item.id} item={item} />
        ))}
      </ul>,
    ),
  );
  const renders = rowRenders();
  renders.begin(host, ".row");
  act(() => bump.forEach((each) => each()));
  expect(renders.end()).toEqual({ rerendered: 10, wasted: 10, added: 0, maxRenders: 1 });
});

test("a row re-rendered by a context it reads counts", () => {
  const view = (theme: number) => (
    <Theme value={theme}>
      <ul>
        {few.map((item) => (
          <ContextRow key={item.id} item={item} />
        ))}
      </ul>
    </Theme>
  );
  act(() => root!.render(view(0)));
  const renders = rowRenders();
  renders.begin(host, ".row");
  act(() => root!.render(view(1)));
  expect(renders.end()).toEqual({ rerendered: 10, wasted: 10, added: 0, maxRenders: 1 });
});

test("a row re-rendered by a store it subscribes to counts", () => {
  act(() =>
    root!.render(
      <ul>
        {few.map((item) => (
          <StoreRow key={item.id} item={item} />
        ))}
      </ul>,
    ),
  );
  const renders = rowRenders();
  renders.begin(host, ".row");
  act(() => {
    version++;
    for (const listener of listeners) listener();
  });
  expect(renders.end()).toEqual({ rerendered: 10, wasted: 10, added: 0, maxRenders: 1 });
});
