import { afterAll, beforeAll, expect, test } from "bun:test";
import { act, memo, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Stabilizer, useStableProps } from "./stableProps";
import { teardownDom } from "../../../test/support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>");
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Props = {
  options: { enabled: boolean; panel?: { label: string; run: () => string } };
  icon: ReactNode;
  items: readonly { id: string }[];
  menu: () => string[];
  onPick?: () => string;
};
let renders = 0;
let seen: Props | undefined;
const Child = memo(function Child(props: Props) {
  renders++;
  seen = props;
  props.menu();
  return null;
});
function Parent(props: Props) {
  return <Child {...useStableProps(props, { menu: [[]] })} />;
}
const Icon = ({ name, onClick }: { name: string; onClick?: () => void }) => (
  <button type="button" aria-label={name} onClick={onClick} />
);

function props(label: string, run: string, rows: string[], items: readonly { id: string }[]): Props {
  return {
    options: { enabled: true, panel: { label, run: () => run } },
    icon: <Icon name="gear" onClick={() => undefined} />,
    items,
    menu: () => [...rows],
    onPick: () => run,
  };
}

test("new objects, elements, callbacks and menu rows with the same parts draw a memoized child once", () => {
  renders = 0;
  const items = [{ id: "a" }];
  const root = createRoot(document.getElementById("root")!);
  act(() => root.render(<Parent {...props("Info", "one", ["x"], items)} />));
  act(() => root.render(<Parent {...props("Info", "two", ["x"], items)} />));
  expect(renders).toBe(1);
  // Every function calls the newest one, nested in an object too.
  expect(seen?.onPick?.()).toBe("two");
  expect(seen?.options.panel?.run()).toBe("two");
  // Data keeps its identity.
  expect(seen?.items).toBe(items);
  // A changed part, or a changed menu row, draws it again.
  act(() => root.render(<Parent {...props("Info!", "two", ["x"], items)} />));
  expect(renders).toBe(2);
  expect(seen?.options.panel?.label).toBe("Info!");
  act(() => root.render(<Parent {...props("Info!", "two", ["x", "y"], items)} />));
  expect(renders).toBe(3);
  expect(seen?.menu()).toEqual(["x", "y"]);
  // A function that goes away is a change.
  act(() => root.render(<Parent {...props("Info!", "two", ["x", "y"], items)} onPick={undefined} />));
  expect(renders).toBe(4);
  expect(seen?.onPick).toBeUndefined();
  act(() => root.unmount());
});

test("a keyed row that leaves its list takes what it held with it", () => {
  // Needs You asks come and go by key; each one's place must not stay held after it goes.
  const stabilizer = new Stabilizer();
  const ask = (id: number) => ({ id: `ask-${id}`, title: `Ask ${id}`, onOpen: () => id, meta: { at: id } });
  const read = (items: readonly unknown[]) => stabilizer.run({ props: { items, onClose: () => 0 }, results: {} });
  read([]);
  const empty = stabilizer.size;
  for (let id = 0; id < 1000; id += 1) read([ask(id), ask(id + 1)]);
  expect(stabilizer.size).toBeLessThan(empty + 20);
  read([]);
  expect(stabilizer.size).toBe(empty);
  // A row that stays keeps its caller.
  const first = read([ask(1), ask(2)]) as { props: { items: { onOpen: () => number }[] } };
  const kept = read([ask(1)]) as { props: { items: { onOpen: () => number }[] } };
  expect(kept.props.items[0]!.onOpen).toBe(first.props.items[0]!.onOpen);
});
