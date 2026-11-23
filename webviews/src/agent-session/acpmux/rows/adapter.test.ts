// The adapter over one chat's snapshots in turn: a row is adapted again only when it changed, or a
// turn's end when its group row did, and every other row keeps its view rows' objects.
import { expect, test } from "bun:test";
import { chatRowsFeed } from "../../../../test/support/chatRowsFeed";
import { turnView } from "../conversation/turns";
import { bookRevision } from "./bookRevision";
import { ChatAdapter } from "./adapter";
import { ChatRowsHost, type ChatRowsPost } from "./host";
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
async function chat(rows: ChatRow[], open: ChatRow[] = []) {
  const store = new ChatRowStore();
  const post: ChatRowsPost = async (method, params) => (method === "chat.rows.open" ? { sid: params.sid } : {});
  const host = new ChatRowsHost(post, store, () => "c");
  await host.open("chat-1");
  const feed = chatRowsFeed(host, post);
  const send = (change: unknown) => feed([JSON.stringify(change)]);
  send({
    kind: "chatWindow",
    replaces: true,
    window: {
      sid: "c",
      cursor: 10,
      edition: 1,
      open: open.map((row) => ({ row })),
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
  expect(bookRevision(next[1]!)).toBe(2);
});

test("each open text delta redraws the shaped answer at the same wire revision", async () => {
  const { snapshot, op } = await chat([row(1, { kind: "user", body: { text: "Prompt" } })], [row(2, { open: true })]);
  const adapter = new ChatAdapter({ sessionId: "s1" });
  const answer = () => turnView(adapter.adapt(snapshot()).rows, new Set()).find((row) => row.kind === "assistant")!;
  const before = answer();
  expect(before.text).toBe("r2");
  op({ op: "text", rowId: 2, text: " hello" });
  const after = answer();
  expect(after.text).toBe("r2 hello");
  expect(after.version).toBeGreaterThan(before.version);
  expect(bookRevision(after)).toBe(1);
  expect(snapshot().rows.find((entry) => entry.id === 2)?.rev).toBe(1);
  op({ op: "text", rowId: 2, text: " world" });
  expect(answer().version).toBeGreaterThan(after.version);
  expect(answer().text).toBe("r2 hello world");
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

test("a decided ask adapted before the chat's harness is known names its mode once the harness is", async () => {
  const ask = row(1, {
    kind: "ask",
    body: {
      ask: "permission",
      permissionId: "perm1",
      decision: { kind: "fullAccess", mode: "acceptEdits" },
      request: { toolCall: { title: "Edit the plan", kind: "edit" }, options: [] },
    },
  });
  const { snapshot } = await chat([ask]);
  // The page's context reads the harness from the chat list as each row is adapted.
  let harness: string | undefined;
  const adapter = new ChatAdapter({
    sessionId: "chat-1",
    get harness() {
      return harness;
    },
  });
  const mode = () => (adapter.adapt(snapshot()).rows[0] as { decision?: { mode?: string } }).decision?.mode;
  expect(mode()).toBe("Full access");
  harness = "claude";
  expect(mode()).toBe("Accept edits");
});
