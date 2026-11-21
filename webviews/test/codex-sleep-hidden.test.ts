// l10n-allow-file: test fixture replies, not shipped UI.
// The Codex app server's `sleep` items ("Wait 45000 ms") are the agent pausing between polls of a
// background build. They draw no row and do not split the reply around them (hiddenTools.ts
// `isCodexSleep`; Lucas, 2026-11-14: "we should not have it").
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved: [string, boolean, unknown][] = ["window", "document"].map((key) => [key, key in scope, scope[key]]);
beforeAll(() => Object.assign(scope, { window: dom.window, document: dom.window.document }));
afterAll(() => teardownDom(saved, { window: dom.window }));

const SESSION = "codex-sleep";
const T0 = 1_794_000_000_000;
let seq = 0;
const event = (kind: string, msg: unknown, dir = "mux") => ({ seq: ++seq, at: T0 + seq * 1_000, dir, kind, msg });
const update = (kind: string, body: Record<string, unknown>) =>
  event(kind, { jsonrpc: "2.0", method: "session/update", params: { sessionId: "agent", update: body } }, "in");
const sleep = (id: string) => [
  update("tool_call", {
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: "Wait 45000 ms",
    kind: "other",
    status: "in_progress",
    _meta: { codexAppServer: { itemType: "sleep" } },
  }),
  update("tool_call_update", {
    sessionUpdate: "tool_call_update",
    toolCallId: id,
    status: "completed",
    _meta: { codexAppServer: { itemType: "sleep" } },
  }),
];
const say = (text: string) =>
  update("agent_message_chunk", { sessionUpdate: "agent_message_chunk", content: { type: "text", text } });

test("a Codex sleep draws no row and leaves the reply around it whole", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const events = [
    event("created", { harness: "codex" }),
    event("turn_started", { client: "watch", prompt: "build it", promptId: "p1" }),
    event("user_message", { client: "watch", promptId: "p1", text: "build it" }),
    say("Waiting on the build. "),
    ...sleep("sleep-1"),
    ...sleep("sleep-2"),
    say("The build passed."),
    event("turn_end", { stopReason: "end_turn", turnId: "t1" }),
    event("turn_result", { promptId: "p1", status: "completed", stopReason: "end_turn", turnId: "t1" }),
  ];
  let rows: Array<{ kind: string; text?: string; items?: Array<{ tool?: { title?: string } }> }> = [];
  const client = AcpmuxDirectClient.replay(SESSION, [...events] as never, (snapshot) => {
    rows = snapshot.rows as never;
  });
  try {
    client.seekReplay(events.at(-1)!.seq);
  } finally {
    client.close();
  }
  const titles = rows.flatMap((row) => (row.items ?? []).flatMap((item) => item.tool?.title ?? []));
  expect(titles.filter((title) => title.startsWith("Wait"))).toEqual([]);
  expect(rows.filter((row) => row.kind === "activity")).toHaveLength(0);
  expect(rows.filter((row) => row.kind === "assistant").map((row) => row.text)).toEqual([
    "Waiting on the build. The build passed.",
  ]);
});
