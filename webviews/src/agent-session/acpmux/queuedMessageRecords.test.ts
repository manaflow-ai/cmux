// Another agent's message waiting in the queue (direct.ts `queuedMessage`), read from the records
// acpmux really writes: a `queued` record (hub/queue.rs `enqueue`, its requeue in hub/digest.rs)
// with its `prompt` blocks, `control`, `trustGate`, `turnId`, and its sender as `fromAgent` or as
// `_meta.provenance` (prompt_provenance.rs `marked`). Every path that rebuilds the pane's queue row
// (`queuedEntry`: the record, a reorder or send-now, a send's state, acpmux's list in `mergeQueue`)
// keeps that message, and an edit (`queue_updated`, hub/queue_edit.rs) drops it, as acpmux drops
// the provenance and `fromAgent` (hub/queue.rs `restore_queue`).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { mergeQueue, queuedMessage } from "./direct";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Daemon = {
  emit: (target: string, step: unknown, at?: number) => void;
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
};
type Entry = { id: string; prompt: string; next?: boolean; message?: { name?: string; text?: string } };
type Shown = { summary?: unknown; queue?: Entry[] };

const blocks = (text: string) => [{ type: "text", text }];

/// A `queued` record as hub/queue.rs `enqueue` writes it, with `fromAgent` for `acpmux send --from`.
const fromAgentRecord = (promptId: string, text: string, agent: string) => ({
  text,
  client: "acpmux",
  promptId,
  turnId: `t-${promptId}`,
  prompt: blocks(text),
  control: "local",
  trustGate: false,
  fromAgent: agent,
});

/// The same record for a session's message: no `fromAgent`, its sender in `_meta.provenance`
/// (prompt_provenance.rs `marked`).
const provenanceRecord = (promptId: string, text: string) => ({
  text,
  client: "acpmux",
  promptId,
  turnId: `t-${promptId}`,
  prompt: blocks(text),
  control: "local",
  trustGate: false,
  _meta: { provenance: { kind: "agent_message", from: "acp:s-deputy", fromName: "coord-deputy" } },
});

/// hub/digest.rs's requeue of a prompt a digest took back: `position` and `requeued`, as above.
const requeuedRecord = (promptId: string, text: string, agent: string) => ({
  ...fromAgentRecord(promptId, text, agent),
  position: 1,
  requeued: true,
});

test("queuedMessage reads acpmux's own queued record shapes", () => {
  expect(queuedMessage(fromAgentRecord("p1", "Build is green", "builder"))).toEqual({
    name: "builder",
    text: "Build is green",
    raw: "Build is green",
  });
  expect(queuedMessage(provenanceRecord("p2", "Rebase first"))).toEqual({
    name: "coord-deputy",
    sessionId: "s-deputy",
    text: "Rebase first",
    raw: "Rebase first",
  });
  expect(queuedMessage(requeuedRecord("p3", "From builder: Lint is green", "builder"))?.text).toBe("Lint is green");
  // The person's own prompt: the same record with no sender.
  const { fromAgent: _, ...person } = fromAgentRecord("p4", "Also update the comment", "builder");
  expect(queuedMessage({ ...person, client: "cmux-pane#1" })).toBeUndefined();
  // A `queue_updated` record (hub/queue_edit.rs) names no sender: an edit is the person's.
  const { _meta: _m, ...edited } = provenanceRecord("p2", "Rebase onto main first");
  expect(queuedMessage(edited)).toBeUndefined();
});

test("acpmux's list (mergeQueue) keeps the record's message, and its null fromAgent drops it", () => {
  const message = queuedMessage(provenanceRecord("p1", "Rebase first"))!;
  const current = [{ id: "p1", prompt: "Rebase first", message }];
  // hub/composers.rs lists `fromAgent: null` for a provenance sender too; the record's message stays
  // while the list does not say the prompt is the person's.
  expect(mergeQueue(current, [{ promptId: "p1", prompt: "Rebase first", client: "acpmux" }])[0]?.message).toEqual(
    message,
  );
  expect(
    mergeQueue(current, [{ promptId: "p1", prompt: "Rebase first", fromAgent: null }])[0]?.message,
  ).toBeUndefined();
});

async function pane() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const view = { shown: {} as Shown };
  const snapshots: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => snapshots.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      view.shown = snapshot as unknown as Shown;
      for (const wake of snapshots.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await until(() => view.shown.summary !== undefined);
  return { daemon, view, until, id: mockHost.sessionId!, close: () => client.close?.() };
}

const senders = (shown: Shown) => (shown.queue ?? []).map((entry) => [entry.id, entry.message?.name ?? null]);

test("a queued agent's message keeps its sender on every rebuild of its row, and an edit drops it", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.emit(id, { mux: "queued", msg: fromAgentRecord("p-bot", "Build is green", "builder") });
    daemon.emit(id, { mux: "queued", msg: provenanceRecord("p-dep", "Rebase first") });
    daemon.emit(id, { mux: "queued", msg: requeuedRecord("p-req", "Lint is green", "linter") });
    await until(() => view.shown.queue?.length === 3);
    expect(senders(view.shown)).toEqual([
      ["p-bot", "builder"],
      ["p-dep", "coord-deputy"],
      ["p-req", "linter"],
    ]);
    // Sent now (`queue_order` with `next`): every row is rebuilt.
    daemon.emit(id, { mux: "queue_order", msg: { promptId: "p-req", next: true, order: ["p-req", "p-bot", "p-dep"] } });
    await until(() => view.shown.queue?.[0]?.id === "p-req");
    expect(senders(view.shown)).toEqual([
      ["p-req", "linter"],
      ["p-bot", "builder"],
      ["p-dep", "coord-deputy"],
    ]);
    // acpmux's own list, as hub/composers.rs lists it: a provenance sender lists `fromAgent: null`
    // only once acpmux names it; this one lists none, so the record's message stays.
    daemon.touch(id, {
      queue: [
        { promptId: "p-req", prompt: "Lint is green", client: "acpmux", fromAgent: "linter" },
        { promptId: "p-bot", prompt: "Build is green", client: "acpmux", fromAgent: "builder" },
        { promptId: "p-dep", prompt: "Rebase first", client: "acpmux" },
      ],
    });
    await until(() => view.shown.queue?.[0]?.id === "p-req" && view.shown.queue.length === 3);
    expect(senders(view.shown)).toEqual([
      ["p-req", "linter"],
      ["p-bot", "builder"],
      ["p-dep", "coord-deputy"],
    ]);
    // The edit's record (hub/queue_edit.rs): no provenance, no `fromAgent`. The row is the person's.
    daemon.emit(id, {
      mux: "queue_updated",
      msg: {
        promptId: "p-dep",
        turnId: "t-p-dep",
        text: "Rebase onto main first",
        prompt: blocks("Rebase onto main first"),
        control: "local",
        trustGate: false,
      },
    });
    await until(() => view.shown.queue?.[2]?.prompt === "Rebase onto main first");
    expect(senders(view.shown)).toEqual([
      ["p-req", "linter"],
      ["p-bot", "builder"],
      ["p-dep", null],
    ]);
    // A later reorder rebuilds the rows again: the edited row stays the person's, the others keep theirs.
    daemon.emit(id, { mux: "queue_order", msg: { promptId: "p-dep", next: true, order: ["p-dep", "p-req", "p-bot"] } });
    await until(() => view.shown.queue?.[0]?.id === "p-dep");
    expect(senders(view.shown)).toEqual([
      ["p-dep", null],
      ["p-req", "linter"],
      ["p-bot", "builder"],
    ]);
  } finally {
    close();
  }
});
