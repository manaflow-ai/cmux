// The adapter over one chat's snapshots in turn: a row is adapted again only when it changed, or a
// turn's end when its group row did, and every other row keeps its view rows' objects.
import { expect, test } from "bun:test";
import { chatRowsFeed } from "../../../../test/support/chatRowsFeed";
import { translate } from "../i18n";
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

/// A chat opened on `rows` (and `refused`, held as holes), with a way to send it an op or a window.
async function chat(rows: ChatRow[], refused?: number[]) {
  const store = new ChatRowStore();
  const post: ChatRowsPost = async (method, params) => (method === "chat.rows.open" ? { sid: params.sid } : {});
  const host = new ChatRowsHost(post, store, () => "c");
  await host.open("chat-1");
  const feed = chatRowsFeed(host, post);
  const send = (change: unknown) => feed([JSON.stringify(change)]);
  const window = (rows: ChatRow[], refused?: number[]) =>
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
        ...(refused ? { refused } : {}),
      },
    });
  window(rows, refused);
  const op = (body: Record<string, unknown>) =>
    send({ kind: "chatOp", sid: "c", replay: false, op: { seq: 11, ...body } });
  return { snapshot: () => store.snapshot("c")!, op, window };
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

test("the page of turns' heads older than the first row held are the earlier prompts, one list until they change", async () => {
  const { snapshot, op } = await chat([row(50, { turn: 50, kind: "user", body: { text: "now" } }), row(51)]);
  const adapter = new ChatAdapter({ sessionId: "s1" });
  const group = (id: number, prompt: number) =>
    row(id, { kind: "group", turn: prompt, body: { head: `prompt ${prompt}`, prompt, promptId: `p${prompt}` } });
  const heads = { rows: [group(11, 10), group(31, 30), group(51, 50)], hasBefore: false, hasAfter: false };
  const first = adapter.adapt({ ...snapshot(), heads });
  // The turn whose prompt is held (row 50) is drawn from its rows, not as an earlier prompt.
  expect(first.earlierPrompts).toEqual([
    { id: "row-10", kind: "user", at: 1794480726000, text: "prompt 10", turnId: "10", promptId: "p10" },
    { id: "row-30", kind: "user", at: 1794480726000, text: "prompt 30", turnId: "30", promptId: "p30" },
  ]);
  // A change below the first row held makes no new list.
  op({ op: "patch", row: row(51, { rev: 2, body: { text: "edited" } }) });
  expect(adapter.adapt({ ...snapshot(), heads }).earlierPrompts).toBe(first.earlierPrompts!);
  // No heads, or none older than what is held: none.
  expect(adapter.adapt({ ...snapshot(), heads: null }).earlierPrompts).toBeUndefined();
  expect(adapter.adapt(snapshot()).earlierPrompts).toBeUndefined();
});

test("a refused row is one line under the id its row will have", async () => {
  const { snapshot } = await chat([row(1), row(3)], [2]);
  const adapter = new ChatAdapter({ sessionId: "s1" });
  const rows = adapter.adapt(snapshot()).rows;
  expect(rows.map((view) => view.id)).toEqual(["row-1", "row-2", "row-3"]);
  const line = rows[1]!;
  expect(line.kind).toBe("notice");
  expect(line.text).toBe(translate("transcript.rowRefused"));
  expect(line.text).not.toBe("transcript.rowRefused");
  // In time order with its neighbours (the view finds a change by `at`).
  expect(line.at).toBe(rows[0]!.at);
  // An unchanged hole keeps its line's object.
  expect(adapter.adapt(snapshot()).rows[1]).toBe(line);
});

test("a later window that holds a refused row draws the row in the line's place, as a new version", async () => {
  const { snapshot, window } = await chat([row(1), row(3)], [2]);
  const adapter = new ChatAdapter({ sessionId: "s1" });
  const line = adapter.adapt(snapshot()).rows[1]!;
  window([row(1), row(2), row(3)]);
  const rows = adapter.adapt(snapshot()).rows;
  expect(rows.map((view) => view.id)).toEqual(["row-1", "row-2", "row-3"]);
  const filled = rows[1]!;
  expect(filled.id).toBe(line.id);
  expect(filled.kind).toBe("assistant");
  expect(filled.text).toBe("r2");
  expect(filled.version).not.toBe(line.version);
});
