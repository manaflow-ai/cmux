// The queue as the pane draws it (queuedMessages.ts `useShownQueue`), through the same path App.tsx
// takes to the transcript: `useShownQueue(snapshot.queue)` -> `queuedMessageRows` -> the waiting
// card's rows. Leo, 2026-11-17: "i also dont like seeing the flicker flash of the Queued blah blah
// blah something". An agent's message acpmux queued and started within 150 ms never becomes a
// `queued-message-*` row; one that waits shows 200 ms after it came; the composer's own prompts read
// the same list.
import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { ownQueue, queuedMessageRowId, queuedMessageRows, useShownQueue } from "./queuedMessages";
import { settleReact } from "../../../../test/support/domTeardown";

type Queue = AcpmuxSnapshot["queue"];

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
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
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  jest.useRealTimers();
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

/// Every transcript row list and composer queue the probe drew, in order.
const rowLists: (readonly AcpmuxRow[])[] = [];
const composerQueues: Queue[] = [];

function Probe({ queue, chat }: { queue: Queue; chat: string }) {
  const shown = useShownQueue(queue, chat);
  rowLists.push(queuedMessageRows(shown));
  composerQueues.push(ownQueue(shown));
  return null;
}

async function draw(container: HTMLElement, queue: Queue, chat = "s1") {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<Probe queue={queue} chat={chat} />);
  });
}

const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));

const agent = (id: string, text: string, extra: Partial<Queue[number]> = {}): Queue[number] => ({
  id,
  prompt: text,
  message: { name: "coord-deputy", sessionId: "s-deputy", text, raw: text },
  ...extra,
});

const everRow = (id: string) => rowLists.some((rows) => rows.some((row) => row.id === queuedMessageRowId(id)));

test("a message queued for 150 ms never reaches the transcript's rows", async () => {
  jest.useFakeTimers();
  rowLists.length = 0;
  const container = installDom();
  await draw(container, []);
  await draw(container, [agent("a1", "CI is green")]);
  await wait(150);
  await draw(container, []);
  await wait(500);
  expect(everRow("a1")).toBe(false);
});

// The person's own send is a whole queued row in the frame the composer clears (Leo, 2026-11-11;
// test/agent-pane-queue-collapse.test.ts): only messages the person did not type wait.
test("the person's own prompt shows at once; a message beside it shows 200 ms after it came", async () => {
  jest.useFakeTimers();
  rowLists.length = 0;
  composerQueues.length = 0;
  const container = installDom();
  await draw(container, []);
  await draw(container, [agent("a1", "CI is green"), { id: "p1", prompt: "Then open a PR" }]);
  expect(composerQueues.at(-1)!.map((entry) => entry.id)).toEqual(["p1"]);
  await wait(199);
  expect(everRow("a1")).toBe(false);
  await wait(1);
  expect(rowLists.at(-1)!.map((row) => row.id)).toEqual([queuedMessageRowId("a1")]);
  expect(composerQueues.at(-1)!.map((entry) => entry.id)).toEqual(["p1"]);
});

test("a chat opened with messages waiting shows them at once, and a guest's held prompt never waits", async () => {
  jest.useFakeTimers();
  rowLists.length = 0;
  const container = installDom();
  await draw(container, [agent("a1", "CI is green")]);
  expect(rowLists.at(-1)!.map((row) => row.id)).toEqual([queuedMessageRowId("a1")]);
  await draw(container, [
    agent("a1", "CI is green"),
    { id: "g1", prompt: "Can you add dark mode?", awaitingOwner: true, author: { id: "u2", name: "Sam" } },
  ]);
  expect(rowLists.at(-1)!.map((row) => row.id)).toEqual([queuedMessageRowId("a1"), queuedMessageRowId("g1")]);
});
