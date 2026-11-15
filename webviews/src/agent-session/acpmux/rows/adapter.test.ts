// The adapter over one chat's snapshots in turn: a row is adapted again only when it changed, or a
// turn's end when its group row did, and every other row keeps its view rows' objects.
import { expect, test } from "bun:test";
import { ChatAdapter } from "./adapter";
import { ChatRowsHost } from "./host";
import { ChatRowStore } from "./store";
import type { ChatRow } from "./wire";

const row = (id: number, extra: Partial<ChatRow> = {}): ChatRow => ({
  id,
  rev: 1,
  kind: "text",
  at: 1794480726,
  open: false,
  body: { text: `r${id}` },
  est: 1,
  ...extra,
});

/// A chat opened on `rows`, with a way to send it an op.
async function chat(rows: ChatRow[]) {
  const store = new ChatRowStore();
  const host = new ChatRowsHost(
    async (method, params) => (method === "chat.rows.open" ? { sid: params.sid } : {}),
    store,
    () => "c",
  );
  await host.open("chat-1");
  let batch = 0;
  const send = (change: unknown) => host.receive({ batch: ++batch, changes: [JSON.stringify(change)] });
  send({
    kind: "chatWindow",
    replaces: true,
    window: {
      sid: "c",
      cursor: 10,
      edition: 1,
      rows,
      hasBefore: false,
      hasAfter: false,
      queue: { entries: [], count: 0 },
    },
  });
  const op = (body: Record<string, unknown>) =>
    send({ kind: "chatOp", sid: "c", replay: false, op: { seq: 11, ...body } });
  return { snapshot: () => store.snapshot("c")!, op };
}

test("a new snapshot adapts only the rows that changed", async () => {
  const { snapshot, op } = await chat([row(1), row(2), row(3)]);
  const adapter = new ChatAdapter({ sessionId: "s1" });
  const first = adapter.adapt(snapshot()).rows;
  op({ op: "patch", row: row(2, { rev: 2, body: { text: "edited" } }) });
  const next = adapter.adapt(snapshot()).rows;
  expect(next[0]).toBe(first[0]!);
  expect(next[2]).toBe(first[2]!);
  expect(next[1]).not.toBe(first[1]!);
  expect(next[1]!.text).toBe("edited");
});

test("a turn's end is adapted again when its group row changes", async () => {
  const group = row(1, { kind: "group", body: { ms: 1000, calls: 1 } });
  const notice = row(2, { kind: "notice", group: 1, body: { notice: "turn_result", seq: 9 } });
  const { snapshot, op } = await chat([group, notice]);
  const adapter = new ChatAdapter({ sessionId: "s1" });
  expect(adapter.adapt(snapshot()).rows.map((summary) => summary.durationMs)).toEqual([1000]);
  op({ op: "patch", row: { ...group, rev: 2, body: { ms: 2500, calls: 2 } } });
  const [summary] = adapter.adapt(snapshot()).rows;
  expect(summary!.durationMs).toBe(2500);
  expect(summary!.toolCount).toBe(2);
});
