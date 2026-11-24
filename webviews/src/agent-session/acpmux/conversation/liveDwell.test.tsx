// The live line's dwell (liveDwell.ts): a burst of statuses collapses to whole changes, a lone change
// after a quiet stretch shows at once, and updates to the shown status pass straight through.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { liveStatusKey, useKeyedDwell, withLiveStatus } from "./liveDwell";
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
  await settleReact(root);
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

let time = 0;
const clock = () => time;
const DWELL = 40;

function Probe({ k, value }: { k: string; value: string }) {
  return <output>{useKeyedDwell(k, value, DWELL, clock)}</output>;
}

const shown = () => container.querySelector("output")!.textContent;
const draw = (k: string, value = k) => act(() => root!.render(<Probe k={k} value={value} />));
const wait = (ms: number) =>
  act(async () => {
    time += ms;
    await new Promise((resolve) => setTimeout(resolve, ms + 5));
  });

test("a change after a quiet stretch shows in the same render", async () => {
  time = 0;
  draw("thinking");
  await wait(DWELL);
  draw("call-1");
  expect(shown()).toBe("call-1");
});

test("a burst inside the dwell waits for its end, then shows only the newest", async () => {
  time = 0;
  draw("thinking");
  await wait(DWELL);
  draw("call-1");
  // Thirty changes faster than the dwell: the line keeps call-1.
  for (let i = 0; i < 30; i++) {
    time += 1;
    draw(i % 2 ? "thinking" : `call-${i + 2}`);
    expect(shown()).toBe("call-1");
  }
  draw("call-last");
  await wait(DWELL);
  expect(shown()).toBe("call-last");
});

test("the shown status's own updates pass through, and a held change draws the newest of them", async () => {
  time = 0;
  draw("thinking");
  await wait(DWELL);
  draw("call-1", "Running grep");
  draw("call-1", "Ran grep");
  expect(shown()).toBe("Ran grep");
  draw("call-2", "Read App.tsx");
  // Held: the shown call as it last read, never its older words.
  expect(shown()).toBe("Ran grep");
  await wait(DWELL);
  expect(shown()).toBe("Read App.tsx");
});

test("coming back to the shown status inside the dwell cancels the held change", async () => {
  time = 0;
  draw("thinking");
  await wait(DWELL);
  draw("call-1");
  draw("thinking");
  draw("call-1");
  await wait(DWELL);
  expect(shown()).toBe("call-1");
});

test("a dwell of 0 shows every change at once", async () => {
  function Zero({ k }: { k: string }) {
    return <output>{useKeyedDwell(k, k, 0, clock)}</output>;
  }
  time = 0;
  act(() => root!.render(<Zero k="a" />));
  act(() => root!.render(<Zero k="b" />));
  expect(shown()).toBe("b");
});

test("the live line keys a call by its id and a state by its name; the held row keeps the newest clock", () => {
  const thinking = { id: "t", kind: "thinking", version: 1, at: 5 } as AcpmuxRow;
  const call = { ...thinking, version: 2, doing: "Read a.ts", doingCall: "c1", heardAt: 9 } as AcpmuxRow;
  const renamed = { ...call, version: 3, doing: "Read b.ts" } as AcpmuxRow;
  expect(liveStatusKey(thinking)).not.toBe(liveStatusKey(call));
  expect(liveStatusKey(call)).toBe(liveStatusKey(renamed));
  const drawn = withLiveStatus(call, thinking);
  expect(drawn.doing).toBeUndefined();
  expect(drawn.heardAt).toBe(9);
  expect(withLiveStatus(call, call)).toBe(call);
});
