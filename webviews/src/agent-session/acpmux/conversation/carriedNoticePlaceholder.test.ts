// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-11-22, on a reply's footer with ~40px of nothing under it, then "Received 2 messages" and
// "Working for 29s": "sometimes you get these way-too-big gaps. i think it's the message recieving not
// properly getting treated like the tool call ish thing it should be and instead as if it were a
// message?". The records, as acpmux logged them: an inbox notice came in as a steer while a turn ran,
// the turn ended without reading it (`turn_result.carriedTo`) and the next turn started with it
// (`turn_started.carried`). acpmux said that turn runs before its `turn_started` landed, so the
// client's typing placeholder was made first, sorted before the carried notice, into the ended turn,
// and drew a blank row under its footer. The placeholder belongs to the turn it waits on, and no
// view draws one.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";
import { settleReact } from "../../../../test/support/domTeardown";

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
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Daemon = {
  record: (target: string, step: unknown, at?: number) => unknown;
  emit: (target: string, step: unknown, at?: number) => void;
  touch: (target: string, fields: Record<string, unknown>) => void;
};

const TURN_A = "turn-a";
const TURN_B = "turn-b";
const NOTICE = "inbox-notice-b";
const THREADS = ["lane-10", "lane-11"].map((from) => ({
  threadId: `from:${from}`,
  label: "messages",
  from: [from],
  count: 1,
  blocker: false,
  preview: `${from} finished setup.`,
  promptIds: [`${from}-p`],
  messages: [{ from, promptId: `${from}-p`, text: `${from} finished setup.` }],
}));
const noticeText = `[inbox] New messages from other agents in 2 threads.\n${THREADS.map((thread) => `- 1 new from ${thread.from[0]}: ${thread.preview}`).join("\n")}`;
const say = (text: string) => ({ update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } });

for (const hostFirst of [true, false])
  test(`a carried inbox notice opens its turn with no blank row over it (acpmux says it runs ${hostFirst ? "before" : "after"} turn_started)`, async () => {
    const { AcpmuxDirectClient } = await import("../direct");
    const { MockAcpmuxSocket, mockHost } = await import("../mock");
    const socket = new MockAcpmuxSocket(() => Promise.resolve());
    const daemon = socket as unknown as Daemon;
    const chat = mockHost.sessionId!;
    daemon.record(chat, {
      mux: "user_message",
      msg: { text: "Set up the two lane VMs", promptId: "p1", turnId: TURN_A },
    });
    daemon.record(chat, { mux: "turn_started", msg: { promptId: "p1", turnId: TURN_A } });
    let rows: AcpmuxRow[] = [];
    const waits: Array<() => void> = [];
    const until = async (check: () => boolean) => {
      while (!check()) await new Promise<void>((resolve) => waits.push(resolve));
    };
    // Lets the socket's messages and the client's snapshots go through (a step can draw nothing new).
    const settled = async () => {
      for (let turn = 0; turn < 50; turn += 1) await new Promise((resolve) => setTimeout(resolve, 0));
    };
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => {
        rows = [...snapshot.rows];
        for (const wake of waits.splice(0)) wake();
      },
      undefined,
      () => socket as unknown as WebSocket,
    );
    try {
      await until(() => rows.some((row) => row.kind === "user"));
      daemon.emit(chat, say("It's done when both VMs finish setup; I'll report back then."));
      // The notice comes in as a steer while the turn runs, and the turn ends without reading it.
      daemon.emit(chat, {
        mux: "user_message",
        msg: {
          text: noticeText,
          promptId: NOTICE,
          turnId: TURN_A,
          client: "acpmux",
          _meta: { provenance: { kind: "inbox_notice", noticeId: NOTICE, threads: THREADS } },
        },
      });
      daemon.emit(chat, { mux: "turn_end", msg: { stopReason: "end_turn", turnId: TURN_A } });
      daemon.emit(chat, {
        mux: "turn_result",
        msg: { status: "completed", turnId: TURN_A, promptId: "p1", carriedTo: { promptId: NOTICE, turnId: TURN_B } },
      });
      daemon.touch(chat, { status: "idle", turn: undefined });
      await settled();
      const started = {
        mux: "turn_started",
        msg: { promptId: NOTICE, turnId: TURN_B, carried: { fromTurnId: TURN_A, promptIds: [NOTICE] } },
      };
      if (hostFirst) {
        daemon.touch(chat, { status: "running", turn: { turnId: TURN_B } });
        await settled();
        daemon.emit(chat, started);
      } else {
        daemon.emit(chat, started);
        daemon.touch(chat, { status: "running", turn: { turnId: TURN_B } });
      }
      await settled();

      // The placeholder is the new turn's: after the notice that opens it, never in the turn before.
      const order = rows.map((row) => row.id);
      const notice = rows.findIndex((row) => row.incoming?.kind === "inbox");
      expect(notice, order.join(" ")).toBeGreaterThan(0);
      expect(order.indexOf("typing"), order.join(" ")).toBeGreaterThan(notice);

      // And no view draws one: between the ended turn's footer and the notice there is nothing.
      const drawn = turnView(rows, new Set(), { now: Date.now(), working: true, agentFamily: "claude" });
      expect(drawn.filter((row) => row.kind === "typing").map((row) => row.id)).toEqual([]);
      const footer = drawn.findIndex((row) => row.kind === "turnSummary");
      const between = drawn.slice(footer + 1).findIndex((row) => row.kind === "user" || row.kind === "working");
      expect(
        drawn.slice(footer + 1, footer + 1 + between).map((row) => `${row.kind}:${row.id}`),
        drawn.map((row) => `${row.kind}:${row.id}`).join("\n"),
      ).toEqual([]);
    } finally {
      client.close?.();
    }
  });

/// The class: a turn that ended keeps no typing row of the client's, wherever one sorted.
test("no ended turn draws the client's typing rows", () => {
  const at = Date.now() - 60_000;
  const row = (id: string, kind: string, offset: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    version: 1,
    at: at + offset,
    kind,
    ...fields,
  });
  const rows: AcpmuxRow[] = [
    row("u1", "user", 0, { text: "Set up the VMs" }),
    row("a1", "assistant", 1_000, { text: "Done when both finish." }),
    row("summary-1", "turnSummary", 2_000, { status: "completed", durationMs: 2_000 }),
    row("typing", "typing", 2_100),
    row("turn-retry", "typing", 2_200),
    row("u2", "user", 3_000, { text: "Next step" }),
    row("a2", "assistant", 4_000, { text: "On it." }),
    row("summary-2", "turnSummary", 5_000, { status: "completed", durationMs: 2_000 }),
  ];
  for (const working of [false, true])
    expect(
      turnView(rows, new Set(), { now: Date.now(), working, agentFamily: "claude" })
        .filter((drawn) => drawn.kind === "typing")
        .map((drawn) => drawn.id),
    ).toEqual([]);
});
