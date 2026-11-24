// The live line's call entry (liveCallEntry.ts): a call done before the entry wait never shows, one
// that runs longer shows whole, a finished call leaves at once, and the shown status's updates pass.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { liveStatusKey, useLiveStatus, withLiveStatus } from "./liveCallEntry";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

let time = 0;
const clock = () => time;
const ENTRY = 40;

const thinking = { id: "live", kind: "thinking", version: 1, at: 0 } as AcpmuxRow;
const call = (id: string, doing = `Read ${id}`): AcpmuxRow =>
  ({ ...thinking, version: 2, doing, doingCall: id }) as AcpmuxRow;

function Probe({ row, entry = ENTRY }: { row: AcpmuxRow; entry?: number }) {
  return <output>{useLiveStatus(row, entry, clock).doing ?? "Thinking"}</output>;
}

const shown = () => container.querySelector("output")!.textContent;
const draw = (row: AcpmuxRow, entry?: number) => act(() => root!.render(<Probe row={row} entry={entry} />));
const wait = (ms: number) =>
  act(async () => {
    time += ms;
    await new Promise((resolve) => setTimeout(resolve, ms + 5));
  });

test("a call done before the entry wait never shows: the line stays on Thinking through a burst", async () => {
  time = 0;
  draw(thinking);
  for (let i = 0; i < 30; i++) {
    time += 5;
    draw(i % 2 ? thinking : call(`c${i}`));
    expect(shown()).toBe("Thinking");
  }
  draw(thinking);
  await wait(ENTRY);
  expect(shown()).toBe("Thinking");
});

test("a call that runs past the entry wait shows, with its newest words", async () => {
  time = 0;
  draw(thinking);
  draw(call("c1", "Running grep"));
  expect(shown()).toBe("Thinking");
  draw(call("c1", "Running grep -n"));
  await wait(ENTRY);
  expect(shown()).toBe("Running grep -n");
  // Its own updates pass straight through.
  draw(call("c1", "Ran grep -n"));
  expect(shown()).toBe("Ran grep -n");
});

test("a finished call leaves the line at once, so its name never stands on the line and its row", async () => {
  time = 0;
  draw(call("c1"));
  expect(shown()).toBe("Read c1");
  draw(thinking);
  expect(shown()).toBe("Thinking");
});

test("an entry wait of 0 names every call at once", () => {
  time = 0;
  draw(thinking, 0);
  draw(call("c1"), 0);
  expect(shown()).toBe("Read c1");
});

test("the live line keys a call by its id and a state by its name; the held row keeps the newest clock", () => {
  const first = { ...call("c1"), heardAt: 9 } as AcpmuxRow;
  const renamed = { ...first, version: 3, doing: "Read b.ts" } as AcpmuxRow;
  expect(liveStatusKey(thinking)).not.toBe(liveStatusKey(first));
  expect(liveStatusKey(first)).toBe(liveStatusKey(renamed));
  const drawn = withLiveStatus(first, thinking);
  expect(drawn.doing).toBeUndefined();
  expect(drawn.heardAt).toBe(9);
  expect(withLiveStatus(first, first)).toBe(first);
});
