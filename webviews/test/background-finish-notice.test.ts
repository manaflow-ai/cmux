// l10n-allow-file: test fixture replies, not shipped UI.
// A background command's finish that acpmux sends the agent as a prompt (`bg-done-<task>`) draws as
// a background turn (conversation/bgDoneNotice.ts): no prompt row, nothing pinned under the running
// turn while it waits, one line naming the task after it. A success's acknowledgement draws nothing;
// a failure's line stands over the agent's reply (Lucas, 2026-11-14).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved: [string, boolean, unknown][] = ["window", "document"].map((key) => [key, key in scope, scope[key]]);
beforeAll(() => Object.assign(scope, { window: dom.window, document: dom.window.document }));
afterAll(() => teardownDom(saved, { window: dom.window }));

const T0 = 1_794_000_000_000;
type Row = { id: string; kind: string; text?: string; background?: { cause?: { weight?: string } } };

async function replay(exit: number) {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
  let seq = 0;
  const event = (kind: string, msg: unknown, dir = "mux") => ({ seq: ++seq, at: T0 + seq * 1_000, dir, kind, msg });
  const say = (text: string) =>
    event(
      "agent_message_chunk",
      { jsonrpc: "2.0", method: "session/update", params: { sessionId: "agent", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } } },
      "in",
    );
  const promptId = "bg-done-bg-1";
  const notice = {
    promptId,
    client: "acpmux",
    text: `[notice from acpmux] Background command finished: Build the app (exit ${exit})`,
    _meta: {
      provenance: {
        bgTaskDescription: "Build the app",
        bgTaskId: "bg-1",
        from: "fromAgent",
        fromName: "acpmux",
        kind: "notice",
        notice: { sender: "acpmux", severity: exit ? "warn" : "info", title: `Background command finished: Build the app (exit ${exit})` },
      },
    },
  };
  const running = [
    event("created", { harness: "codex" }),
    event("turn_started", { client: "watch", prompt: "build it", promptId: "p1" }),
    event("user_message", { client: "watch", promptId: "p1", text: "build it" }),
    say("Building in the background."),
    // The finish comes while the turn still runs: it waits for the next turn.
    event("queued", notice),
  ];
  const ended = [
    ...running,
    say(" Done for now."),
    event("turn_end", { stopReason: "end_turn", turnId: "t1" }),
    event("turn_result", { promptId: "p1", status: "completed", stopReason: "end_turn", turnId: "t1" }),
    event("user_message", notice),
    event("turn_started", { client: "acpmux", prompt: notice.text, promptId }),
    say(exit ? "The build failed: the fleet is offline." : "The notice confirms the build."),
    event("turn_end", { stopReason: "end_turn", turnId: "t2" }),
    event("turn_result", { promptId, status: "completed", stopReason: "end_turn", turnId: "t2" }),
  ];
  const read = (events: typeof ended) => {
    let snapshot: { rows: Row[]; queue?: unknown[] } = { rows: [] };
    const client = AcpmuxDirectClient.replay("bg-finish", [...events] as never, (next) => {
      snapshot = next as never;
    });
    try {
      client.seekReplay(events.at(-1)!.seq);
    } finally {
      client.close();
    }
    return snapshot;
  };
  const whileRunning = read(running);
  const after = read(ended);
  return {
    queued: whileRunning.queue ?? [],
    rows: after.rows,
    drawn: turnView(after.rows as never, new Set(), { agentFamily: "codex" }) as Row[],
  };
}

const texts = (rows: Row[]) => rows.flatMap((row) => (row.text ? [row.text] : []));

test("a background success waits unseen, then draws one line and no prompt or acknowledgement", async () => {
  const { queued, rows, drawn } = await replay(0);
  expect(queued).toEqual([]);
  expect(rows.some((row) => row.kind === "user" && row.text?.includes("Background command finished"))).toBe(false);
  const line = drawn.find((row) => row.kind === "backgroundTurn");
  expect(line?.background?.cause?.weight).toBe("result");
  expect(texts(drawn).some((text) => text.includes("The notice confirms the build."))).toBe(false);
});

test("a background failure draws its line over the agent's reply, with no prompt row", async () => {
  const { queued, rows, drawn } = await replay(69);
  expect(queued).toEqual([]);
  expect(rows.some((row) => row.kind === "user" && row.text?.includes("Background command finished"))).toBe(false);
  const at = drawn.findIndex((row) => row.kind === "backgroundTurn");
  expect(drawn[at]?.background?.cause?.weight).toBe("failure");
  const reply = drawn.findIndex((row) => row.text === "The build failed: the fleet is offline.");
  expect(reply).toBeGreaterThan(at);
});
