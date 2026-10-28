// l10n-allow-file: test fixtures (made-up people and prompts).
// A guest's held message (design/chat-multiplayer.md, "Held message card"): it draws in the
// transcript with Approve and Decline, Approve sends `_acpmux/queue_approve` and Decline
// `_acpmux/queue_decline` with the chat's and the prompt's ids, a declined one leaves one quiet line,
// and a teammate's or the owner's own queued prompt is the composer's queue row as before.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import type { Participant } from "../multiplayer/participants";
import { QueuedMessageCard, type QueuedMessageActionsValue } from "./QueuedMessageCard";
import { ownQueue, queuedMessageRows } from "./queuedMessages";
import { TurnActionsContext } from "./turnActions";

const CY: Participant = { id: "guest:sh-1.g-1", name: "Cy Park" };
const ANA: Participant = { id: "tailnet:ana@example.com", name: "Ana" };
const ASK = "Could it also retry on 429?\nAnd honor Retry-After.";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved)
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  const w = dom.window;
  Object.assign(scope, {
    window: w,
    document: w.document,
    navigator: w.navigator,
    Node: w.Node,
    HTMLElement: w.HTMLElement,
    Element: w.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = w.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

/// The held card with an `answerHeld` that records its calls.
async function heldCard(row: AcpmuxRow) {
  const calls: [string, boolean][] = [];
  const actions = {
    answerHeld: async (promptId: string, approve: boolean) => {
      calls.push([promptId, approve]);
      return true;
    },
  } as unknown as QueuedMessageActionsValue;
  const host = await render(
    <TurnActionsContext.Provider value={{ queuedMessages: () => actions }}>
      <QueuedMessageCard row={row} onOpen={() => undefined} />
    </TurnActionsContext.Provider>,
  );
  const button = (label: string) =>
    [...host.querySelectorAll("button")].find((each) => each.textContent === label) as HTMLButtonElement | undefined;
  return { host, calls, button };
}

const rowOf = (queue: AcpmuxSnapshot["queue"]) => queuedMessageRows(queue)[0]!;

test("a guest's held prompt draws as their message with Approve, Decline and Waiting for you", async () => {
  const row = rowOf([{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true }]);
  expect(row.queuedMessage).toEqual({ promptId: "g-1", person: CY, held: true });
  const { host, button } = await heldCard(row);
  expect(host.querySelector(".cv-held[data-held]")).not.toBeNull();
  expect(host.querySelector(".cv-received__name")?.textContent).toBe("Cy Park (guest)");
  expect(host.querySelector(".cv-received__queued")?.textContent).toBe("Waiting for you");
  expect(button("Approve")).toBeDefined();
  expect(button("Decline")).toBeDefined();
});

test("Approve and Decline answer the held prompt by its id, once each press", async () => {
  const row = rowOf([{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true }]);
  const { calls, button } = await heldCard(row);
  await act(async () => button("Approve")!.click());
  expect(calls).toEqual([["g-1", true]]);
  // The first answer is on its way: both buttons wait for it.
  expect(button("Decline")!.disabled).toBe(true);
  await act(async () => root!.unmount());
  root = undefined;
  const again = await heldCard(row);
  await act(async () => again.button("Decline")!.click());
  expect(again.calls).toEqual([["g-1", false]]);
});

test("Return on the focused held card approves it", async () => {
  const { host, calls } = await heldCard(rowOf([{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true }]));
  const card = host.querySelector<HTMLElement>(".cv-held")!;
  await act(async () => {
    card.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(calls).toEqual([["g-1", true]]);
});

test("approved, it waits as a queued message with no Approve or Decline", async () => {
  const { host, button } = await heldCard(rowOf([{ id: "g-1", prompt: ASK, author: CY }]));
  expect(host.querySelector(".cv-received__queued")?.textContent).toBe("Read after this turn");
  expect(button("Approve")).toBeUndefined();
  expect(host.querySelector(".cv-held[data-held]")).toBeNull();
});

test("a teammate's queued prompt and the owner's own stay the composer's queue", () => {
  const teammate = { id: "t-1", prompt: "Bump the timeout", author: ANA };
  const own = { id: "p-1", prompt: "Then run the tests" };
  const queue = [teammate, own];
  expect(queuedMessageRows(queue)).toEqual([]);
  expect(ownQueue(queue)).toBe(queue);
  // A guest's prompt, held or approved, leaves the composer's queue for the transcript.
  const guest = { id: "g-1", prompt: ASK, author: CY, awaitingOwner: true };
  expect(ownQueue([teammate, guest, own])).toEqual([teammate, own]);
  expect(ownQueue([{ ...guest, awaitingOwner: undefined }, own])).toEqual([own]);
});

type Daemon = { emit: (target: string, step: unknown) => void };

test("the client sends queue_approve and queue_decline, and a declined prompt leaves one line", async () => {
  dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  for (const key of ["window", "document"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document });
  const log: { method: string; params?: Record<string, unknown> }[] = [];
  (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog = log;
  saved.set("cmuxGalleryLog", undefined);
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  let shown = {} as AcpmuxSnapshot;
  const waiters: (() => void)[] = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => waiters.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot as AcpmuxSnapshot;
      for (const wake of waiters.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    await until(() => shown.summary !== undefined);
    const id = mockHost.sessionId!;
    const fromCy = { provenance: { kind: "person_message", from: CY.id, fromName: CY.name } };
    const daemon = socket as unknown as Daemon;
    daemon.emit(id, { mux: "queued", msg: { promptId: "g-1", text: ASK, awaitingOwner: true, _meta: fromCy } });
    daemon.emit(id, { mux: "queued", msg: { promptId: "g-2", text: "Keep it short", awaitingOwner: true, _meta: fromCy } });
    await until(() => shown.queue?.length === 2);
    expect(shown.queue.map((entry) => [entry.id, entry.awaitingOwner, entry.author?.id])).toEqual([
      ["g-1", true, CY.id],
      ["g-2", true, CY.id],
    ]);
    // Approve: acpmux records `queue_approved`, and the prompt waits as any queued prompt.
    await client.answerHeld("g-1", true);
    await until(() => shown.queue.find((entry) => entry.id === "g-1")?.awaitingOwner === undefined);
    // Decline: the prompt leaves the queue and its declined line is a transcript row.
    await client.answerHeld("g-2", false);
    await until(() => shown.queue.length === 1);
    const sent = log.filter((each) => each.method.includes("queue_"));
    expect(sent.map((each) => [each.method, each.params?.sessionId, each.params?.promptId])).toEqual([
      ["acpmux _acpmux/queue_approve", id, "g-1"],
      ["acpmux _acpmux/queue_decline", id, "g-2"],
    ]);
    const declined = shown.rows.find((row) => row.id === "declined-g-2");
    expect(declined?.queuedMessage).toEqual({ promptId: "g-2", person: CY, declined: true });
    expect(declined?.text).toBe("Keep it short");
  } finally {
    client.close?.();
    delete (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog;
  }
});

test("a declined line reads Declined: and its first line, and opens on a click", async () => {
  const row: AcpmuxRow = {
    id: "declined-g-2",
    version: 1,
    at: 0,
    kind: "queuedMessage",
    text: ASK,
    incoming: { kind: "message", message: { name: CY.name, text: ASK, raw: ASK } },
    queuedMessage: { promptId: "g-2", person: CY, declined: true },
    untyped: true,
  };
  const { host } = await heldCard(row);
  const line = host.querySelector<HTMLButtonElement>(".cv-declined__line")!;
  expect(line.querySelector(".cv-declined__text")?.textContent).toBe("Declined: Could it also retry on 429?");
  expect(host.querySelector(".cv-declined__body")).toBeNull();
  await act(async () => line.click());
  expect(line.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-declined__body")?.textContent).toBe(ASK);
});
