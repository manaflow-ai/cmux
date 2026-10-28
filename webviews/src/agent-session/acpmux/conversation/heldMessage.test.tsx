// l10n-allow-file: test fixtures (made-up people and prompts).
// A guest's held message on its card (design/chat-multiplayer.md, "Held message card"): its whole
// record (text, images, every attachment) with Approve and Decline only when the pane holds that
// record at its current revision (the model's rule: heldPrompts.test.tsx), the revision it was drawn
// with on Approve, one quiet line once declined, the native relay's allowlist for what it sends, and
// a teammate's or the owner's own queued prompt as the composer's queue row as before.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import type { Participant } from "../multiplayer/participants";
import { QueuedMessageCard, type HeldAnswer, type QueuedMessageActionsValue } from "./QueuedMessageCard";
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
  // A test that connected a client first keeps its window: the saved globals stay the ones from before it.
  const fresh = !dom;
  dom ??= new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) if (fresh || !saved.has(key)) saved.set(key, scope[key]);
  const w = dom.window;
  const main = w.document.createElement("main");
  main.id = "root";
  w.document.body.append(main);
  Object.assign(scope, {
    window: w,
    document: w.document,
    navigator: w.navigator,
    Node: w.Node,
    HTMLElement: w.HTMLElement,
    Element: w.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = main;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

/// The held card with an `answerHeld` that records its calls and answers `result`.
async function heldCard(row: AcpmuxRow, result: HeldAnswer = "ok") {
  const calls: [string, boolean][] = [];
  const actions = {
    answerHeld: async (promptId: string, approve: boolean) => {
      calls.push([promptId, approve]);
      return result;
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
  const row = rowOf([{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true, revision: 0 }]);
  expect(row.queuedMessage).toEqual({ promptId: "g-1", person: CY, held: true, revision: 0 });
  const { host, button } = await heldCard(row);
  expect(host.querySelector(".cv-held[data-held]")).not.toBeNull();
  expect(host.querySelector(".cv-received__name")?.textContent).toBe("Cy Park (guest)");
  expect(host.querySelector(".cv-received__queued")?.textContent).toBe("Waiting for you");
  expect(button("Approve")).toBeDefined();
  expect(button("Decline")).toBeDefined();
});

test("Approve and Decline answer the held prompt by its id, once each press", async () => {
  const row = rowOf([{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true, revision: 0 }]);
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

test("a guest's edit since the owner looked is said quietly in the row, and they answer again", async () => {
  const { host, calls, button } = await heldCard(
    rowOf([{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true, revision: 0 }]),
    "stale",
  );
  await act(async () => button("Approve")!.click());
  expect(calls).toEqual([["g-1", true]]);
  expect(host.querySelector(".cv-received__queued")?.textContent).toBe("Edited since you looked");
  expect(button("Approve")!.disabled).toBe(false);
});

test("Return on the focused held card approves it", async () => {
  const { host, calls } = await heldCard(
    rowOf([{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true, revision: 0 }]),
  );
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
  const guest = { id: "g-1", prompt: ASK, author: CY, awaitingOwner: true, revision: 0 };
  expect(ownQueue([teammate, guest, own])).toEqual([teammate, own]);
  expect(ownQueue([{ ...guest, awaitingOwner: undefined }, own])).toEqual([own]);
});

async function connectedClient() {
  if (!dom) {
    dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
    for (const key of ["window", "document"]) saved.set(key, scope[key]);
    Object.assign(scope, { window: dom.window, document: dom.window.document });
  }
  const log: { method: string; params?: Record<string, unknown> }[] = [];
  (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog = log;
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const view = { shown: {} as AcpmuxSnapshot };
  const waiters: (() => void)[] = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => waiters.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      view.shown = snapshot as AcpmuxSnapshot;
      for (const wake of waiters.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await until(() => view.shown.summary !== undefined);
  const daemon = socket as unknown as {
    emit: (target: string, step: unknown) => void;
    touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
  };
  const close = () => {
    client.close?.();
    delete (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog;
  };
  return { client, daemon, view, until, log, id: mockHost.sessionId!, close };
}

const fromCyMeta = { provenance: { kind: "person_message", from: CY.id, fromName: CY.name } };

test("a declined guest prompt leaves one quiet line in the transcript", async () => {
  const { client, daemon, view, until, id, close } = await connectedClient();
  try {
    daemon.emit(id, {
      mux: "queued",
      msg: { promptId: "g-2", text: "Keep it short", awaitingOwner: true, revision: 0, _meta: fromCyMeta },
    });
    await until(() => view.shown.queue?.length === 1);
    await client.answerHeld("g-2", false);
    await until(() => view.shown.queue.length === 0);
    const declined = view.shown.rows.find((row) => row.id === "declined-g-2");
    expect(declined?.queuedMessage).toEqual({ promptId: "g-2", person: CY, declined: true });
    expect(declined?.text).toBe("Keep it short");
  } finally {
    close();
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

test("the card's Approve names the revision it was drawn with, not a newer one", async () => {
  const row = rowOf([{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true, revision: 3 }]);
  expect(row.queuedMessage?.revision).toBe(3);
  const revisions: (number | undefined)[] = [];
  const actions = {
    answerHeld: async (_promptId: string, _approve: boolean, revision?: number) => {
      revisions.push(revision);
      return "ok" as const;
    },
  } as unknown as QueuedMessageActionsValue;
  const host = await render(
    <TurnActionsContext.Provider value={{ queuedMessages: () => actions }}>
      <QueuedMessageCard row={row} onOpen={() => undefined} />
    </TurnActionsContext.Provider>,
  );
  const approve = [...host.querySelectorAll("button")].find((each) => each.textContent === "Approve")!;
  await act(async () => approve.click());
  expect(revisions).toEqual([3]);
});

test("the requests the pane sends fit the native relay's param allowlist", async () => {
  const { readFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const swift = readFileSync(
    join(
      import.meta.dir,
      "../../../../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift",
    ),
    "utf8",
  );
  const allowed = (method: string) => {
    const match = new RegExp(`"${method}": \\(\\[([^\\]]*)\\]`).exec(swift);
    return new Set(
      (match?.[1] ?? "")
        .split(",")
        .map((each) => each.trim().replace(/"/g, ""))
        .filter(Boolean),
    );
  };
  const sent: Record<string, Record<string, unknown>> = {
    "_acpmux/queue_approve": { sessionId: "s", promptId: "p", revision: 0 },
    "_acpmux/queue_decline": { sessionId: "s", promptId: "p" },
    "_acpmux/queue_get": { sessionId: "s", promptId: "p" },
  };
  for (const [method, params] of Object.entries(sent))
    for (const key of Object.keys(params)) expect([method, key, allowed(method).has(key)]).toEqual([method, key, true]);
});

test("an updating card offers no Approve and says Updating…", async () => {
  const row = rowOf([{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true, revision: 0, updating: true }]);
  const { host, calls, button } = await heldCard(row);
  expect(host.querySelector(".cv-received__queued")?.textContent).toBe("Updating…");
  expect(button("Approve")!.disabled).toBe(true);
  await act(async () => button("Approve")!.click());
  expect(calls).toEqual([]);
});

test("Approve on a card drawn at revision r sends r after the client heard r+1", async () => {
  const { client, daemon, view, until, log, id, close } = await connectedClient();
  try {
    daemon.emit(id, {
      mux: "queued",
      msg: { promptId: "g-1", text: "Retry on 429", awaitingOwner: true, revision: 4, _meta: fromCyMeta },
    });
    await until(() => view.shown.queue?.length === 1);
    // The card as drawn now, wired to the client as App.tsx wires it.
    const drawn = queuedMessageRows(view.shown.queue)[0]!;
    const actions = {
      answerHeld: (promptId: string, approve: boolean, revision?: number) =>
        client.answerHeld(promptId, approve, revision).then(() => "ok" as const),
    } as unknown as QueuedMessageActionsValue;
    const host = await render(
      <TurnActionsContext.Provider value={{ queuedMessages: () => actions }}>
        <QueuedMessageCard row={drawn} onOpen={() => undefined} />
      </TurnActionsContext.Provider>,
    );
    // The guest's edit reaches the client; the card on screen is not drawn again.
    daemon.emit(id, {
      mux: "queue_updated",
      msg: { promptId: "g-1", text: "Retry on 429 and 503", awaitingOwner: true, revision: 5, _meta: fromCyMeta },
    });
    await until(() => view.shown.queue[0]?.revision === 5);
    const approve = [...host.querySelectorAll("button")].find((each) => each.textContent === "Approve")!;
    await act(async () => approve.click());
    await until(() => log.some((each) => each.method === "acpmux _acpmux/queue_approve"));
    // acpmux answers queue.stale to revision 4: the owner never approves text they did not see.
    expect(log.find((each) => each.method === "acpmux _acpmux/queue_approve")?.params).toEqual({
      sessionId: id,
      promptId: "g-1",
      revision: 4,
    });
  } finally {
    close();
  }
});

test("a listing never makes a held card approvable, whatever its preview", async () => {
  const { mergeQueue } = await import("../direct");
  // A short message: acpmux's preview is its whole text, with no "…".
  const listed = [
    { promptId: "g-1", prompt: "Retry on 429", fromAgent: null, author: CY, awaitingOwner: true, revision: 0 },
  ];
  const [entry] = mergeQueue([], listed);
  const row = queuedMessageRows([entry!])[0]!;
  expect(row.queuedMessage).toMatchObject({ held: true, updating: true });
  const { host, calls, button } = await heldCard(row);
  expect(button("Approve")!.disabled).toBe(true);
  await act(async () => button("Approve")!.click());
  expect(calls).toEqual([]);
  expect(host.querySelector(".cv-received__queued")?.textContent).toBe("Updating…");
  // A row with no record revision at all is never approvable, however it was made.
  expect(rowOf([{ id: "g-2", prompt: ASK, author: CY, awaitingOwner: true }]).queuedMessage?.updating).toBe(true);
});

test("a held card shows its record's whole text and every attachment", async () => {
  const { daemon, view, until, id, close } = await connectedClient();
  try {
    const text = Array.from({ length: 14 }, (_, index) => `Line ${index + 1} of the guest's request.`).join("\n");
    daemon.emit(id, {
      mux: "queued",
      msg: {
        promptId: "g-1",
        text,
        awaitingOwner: true,
        revision: 0,
        inlineParts: [
          { kind: "text", text },
          { kind: "document", name: "spec.pdf", mimeType: "application/pdf", size: 2048, pageCount: 3 },
          { kind: "audio", name: "note.m4a", mimeType: "audio/mp4", size: 4096 },
          { kind: "resource_link", name: "retry.ts", uri: "file:///repo/src/retry.ts", mimeType: "text/plain" },
        ],
        _meta: fromCyMeta,
      },
    });
    await until(() => view.shown.queue?.length === 1);
    const row = queuedMessageRows(view.shown.queue)[0]!;
    expect(row.inlineParts?.map((part) => part.kind)).toEqual(["text", "document", "audio", "file"]);
    const { host } = await heldCard(row);
    // Drawn whole: no cut, no Show more, every line there.
    expect(host.querySelector(".cv-received__body[data-cut]")).toBeNull();
    expect(host.querySelector(".cv-received__show")).toBeNull();
    expect(host.querySelector(".cv-received__text")?.textContent).toContain("Line 14 of the guest's request.");
    const names = [...host.querySelectorAll(".cv-message__files .acpmux-file-chip__name")].map(
      (each) => each.textContent,
    );
    expect(names).toEqual(["retry.ts", "spec.pdf", "note.m4a"]);
  } finally {
    close();
  }
});
