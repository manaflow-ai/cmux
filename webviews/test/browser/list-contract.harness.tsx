// One registered list (test/list-contract/<name>.fixture.tsx) at n rows, for the list contract
// (test/list-contract.browser.test.ts): `?list=<name>&n=<rows>`. The page owns the fixture's data,
// clock and selection, and `window.__list` moves them one event at a time.
import { useCallback, useLayoutEffect, useState, type ReactNode } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { UiProvider } from "../../src/ui/UiProvider";
import type { ListFixture } from "../list-contract/listFixture";

export type ListPage = {
  ready: Promise<void>;
  meta: Omit<ListFixture, "item" | "change" | "render"> & { canChange: boolean };
  change(index: number): void;
  select(index: number): void;
  tick(): void;
  width(px: number): void;
};

/// The box the list is drawn in.
export const LIST_BOX = { width: 420, height: 600 };
const START = Date.UTC(2026, 10, 18, 9);

const fixtures = import.meta.glob<{ default: ListFixture }>("../list-contract/*.fixture.tsx");
const query = new URLSearchParams(location.search);
const name = query.get("list") ?? "";
const n = Number(query.get("n") ?? 1000);
const load = fixtures[`../list-contract/${name}.fixture.tsx`];
if (!load) throw new Error(`no list fixture named ${name}`);
const fixture = (await load()).default;

let set: (update: (state: State) => State) => void = () => {};
type State = { items: readonly unknown[]; now: number; selected: number | undefined };

// The page's own parts hand the list stable props (the compiler keeps them), so what the contract
// counts is the list's.
function Host(): ReactNode {
  const [state, setState] = useState<State>(() => ({
    items: Array.from({ length: n }, (_, index) => fixture.item(index, n)),
    now: START,
    selected: undefined,
  }));
  useLayoutEffect(() => {
    set = setState;
  }, []);
  const onSelect = useCallback((index: number) => setState((previous) => ({ ...previous, selected: index })), []);
  const Render = fixture.render;
  return <Render items={state.items} now={state.now} selected={state.selected} onSelect={onSelect} />;
}

const root = document.getElementById("root")!;
document.body.style.margin = "0";
Object.assign(root.style, {
  width: `${LIST_BOX.width}px`,
  height: `${LIST_BOX.height}px`,
  display: "flex",
  flexDirection: "column",
  overflow: "hidden",
});
// Each event commits synchronously, so the commit hook sees it before the test's frame wait ends.
const update = (next: (state: State) => State) => flushSync(() => set(next));
const { item: _item, change, render: _render, ...meta } = fixture;
const page: ListPage = {
  ready: new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
  meta: { ...meta, canChange: change !== undefined },
  change: (index) =>
    update((state) => ({ ...state, items: state.items.map((item, at) => (at === index ? change!(item) : item)) })),
  select: (index) => update((state) => ({ ...state, selected: index })),
  tick: () => update((state) => ({ ...state, now: state.now + 60_000 })),
  width: (px) => {
    root.style.width = `${px}px`;
  },
};
createRoot(root).render(
  <UiProvider container={root}>
    <Host />
  </UiProvider>,
);
(window as unknown as { __list: ListPage }).__list = page;
