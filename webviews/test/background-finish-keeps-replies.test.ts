// l10n-allow-file: test fixture replies, not shipped UI.
// A reply the agent wrote in a turn a background command's finish opened (`bg-done-<task>`,
// conversation/bgDoneNotice.ts) still draws when it says something. Leo, 2026-11-21, on his
// coordinator's chat: the pane drew his message, "Used a tool and ran a command / Worked for 18s",
// no reply, then the next turn's text ("i wonder if there's not great stuff inside of cmux-next's
// tools/skills/whatever say the wrap up or whatnot where you guys somehow ignore things? or things
// dont get rendeed?"). The daemon held the reply. The recorded order (session claude-sr2-coord, seq
// 1009805..1010120): a finish notice opened the turn; 15 s in, his message came as a steer; the
// agent ran two calls, another agent's message steered in, the agent wrote him five paragraphs, and
// the turn ended `completed`. The pane closed every successful finish's turn as quiet, whatever it
// said, so the reply was hidden for good, with no line to open it from.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved: [string, boolean, unknown][] = ["window", "document"].map((key) => [key, key in scope, scope[key]]);
beforeAll(() => Object.assign(scope, { window: dom.window, document: dom.window.document }));
afterAll(() => teardownDom(saved, { window: dom.window }));

const T0 = 1_795_238_000_000;
type Row = {
  id: string;
  kind: string;
  text?: string;
  inBackground?: string;
  background?: { quiet?: boolean; running?: boolean; cause?: { weight?: string } };
};
type Event = { seq: number; at: number; dir: string; kind: string; msg: unknown };

const REPLY =
  "I sent your message and screenshot word for word to the animation lane.\n\nIt has four things to do, in order:\n1. Catch the missing gap.\n2. Build the simulation harness.\n\nIt stops when all of that has landed.";
const REPORT =
  "The deploy did not happen: the script refused to run with no target.\n\nI started it again with `--local` and the same timed pass.";
const ACK = "The notice confirms the build.";

/// The events of a chat whose second turn a background finish opened. `steer`: the person's message
/// 15 s into that turn, as Leo's came; `reply`: what the agent then wrote; `agentSteer`: another
/// agent's message steered in before the reply and carried to the next turn, as in the recording.
function chat(options: { steer?: string; reply: string; agentSteer?: boolean; ended?: boolean }): Event[] {
  let seq = 0;
  const events: Event[] = [];
  const event = (kind: string, msg: unknown, dir = "mux") => {
    events.push({ seq: (seq += 1), at: T0 + seq * 1_000, dir, kind, msg });
  };
  const update = (kind: string, data: Record<string, unknown>, segment?: string) =>
    event(
      kind,
      {
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: "agent",
          ...(segment && { _meta: { acpmux: { segment } } }),
          update: { sessionUpdate: kind, ...data },
        },
      },
      "in",
    );
  const say = (text: string, segment: string) => {
    // Streamed in pieces, as the daemon logs them: the row is made at the first chunk.
    for (let at = 0; at < text.length; at += 24)
      update("agent_message_chunk", { content: { type: "text", text: text.slice(at, at + 24) } }, segment);
  };
  const call = (id: string, title: string) => {
    update("tool_call", { toolCallId: id, title, kind: "execute", status: "pending" });
    update("tool_call_update", { toolCallId: id, title, status: "in_progress" });
    update("tool_call_update", { toolCallId: id, status: "completed" });
  };
  const promptId = "bg-done-bg-58147aa2ecdb";
  const title = "Background command finished: lane-gh-broker health (exit 0)";
  const notice = {
    promptId,
    client: "acpmux",
    text: `[notice from acpmux] ${title}`,
    _meta: {
      provenance: {
        bgTaskId: "bg-58147aa2ecdb",
        from: "fromAgent",
        fromName: "acpmux",
        kind: "notice",
        notice: { sender: "acpmux", severity: "info", title },
      },
    },
  };
  event("created", { harness: "claude" });
  event("user_message", { client: "pane", promptId: "p1", text: "check the broker", _meta: origin() });
  event("turn_started", { client: "pane", prompt: "check the broker", promptId: "p1", turnId: "t1" });
  say("Checking it in the background.", "t1.a.1");
  event("turn_end", { stopReason: "end_turn", turnId: "t1" });
  event("turn_result", { promptId: "p1", status: "completed", stopReason: "end_turn", turnId: "t1" });
  // The finish opens the agent's own turn.
  event("user_message", notice);
  event("turn_started", { client: "acpmux", prompt: notice.text, promptId, turnId: "t2", persons: false });
  if (options.steer !== undefined) {
    event("user_message", { client: "pane", promptId: "p2", steer: true, text: options.steer, _meta: origin() });
    call("c1", "mcp__acpmux__bg_start");
    event("steer_read", { promptId: "p2", turnId: "t2" });
    call("c2", "leo-forward --last 1");
  }
  if (options.agentSteer)
    event("user_message", {
      client: "peer",
      promptId: "msg_1",
      steer: true,
      text: "[message 1 from lane-11/census (an agent, not Leo)] rows please",
      _meta: { provenance: { from: "fromAgent", fromName: "lane-11/census", kind: "agent_message" } },
    });
  say(options.reply, "t2.a.1");
  if (options.ended === false) return events;
  event("turn_end", { stopReason: "end_turn", turnId: "t2" });
  event("turn_result", { promptId, status: "completed", stopReason: "end_turn", turnId: "t2" });
  if (options.agentSteer) {
    event("turn_started", { carried: { fromTurnId: "t2", promptIds: ["msg_1"] }, client: "peer", turnId: "t3" });
    say("The census lane asked for the Mac rows.", "t3.a.1");
    event("turn_end", { stopReason: "end_turn", turnId: "t3" });
    event("turn_result", { status: "completed", stopReason: "end_turn", turnId: "t3" });
  }
  return events;
}

function origin() {
  return { origin: { actor: "person", verified: true } };
}

async function draw(events: Event[], family = "claude") {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
  let snapshot: { rows: Row[] } = { rows: [] };
  const client = AcpmuxDirectClient.replay("bg-finish-replies", [...events] as never, (next) => {
    snapshot = next as never;
  });
  try {
    client.seekReplay(events.at(-1)!.seq);
  } finally {
    client.close();
  }
  return { rows: snapshot.rows, drawn: turnView(snapshot.rows as never, new Set(), { agentFamily: family }) as Row[] };
}

const drawnText = (rows: Row[]) =>
  rows
    .filter((row) => row.kind === "assistant")
    .map((row) => row.text ?? "")
    .join("\n");
const FAMILIES = ["claude", "codex", undefined] as const;

test("Leo's recording: a reply to the person's steer into a background finish's turn draws", async () => {
  for (const family of FAMILIES) {
    const { drawn } = await draw(chat({ steer: "it is noticeably bad", reply: REPLY, agentSteer: true }), family);
    const said = drawnText(drawn);
    expect(said, String(family)).toContain("I sent your message and screenshot word for word");
    expect(said, String(family)).toContain("It stops when all of that has landed.");
    // In order: his message, then the reply to it, then the next turn's words.
    const steer = drawn.findIndex((row) => row.kind === "user" && row.text === "it is noticeably bad");
    const reply = drawn.findIndex((row) => row.kind === "assistant" && row.text?.startsWith("I sent your message"));
    const next = drawn.findIndex((row) => row.kind === "assistant" && row.text?.startsWith("The census lane"));
    expect(steer, String(family)).toBeGreaterThanOrEqual(0);
    expect(reply, String(family)).toBeGreaterThan(steer);
    expect(next, String(family)).toBeGreaterThan(reply);
  }
});

test("the reply to the person's steer draws while the finish's turn still runs", async () => {
  const { drawn } = await draw(chat({ steer: "it is noticeably bad", reply: REPLY, ended: false }));
  expect(drawnText(drawn)).toContain("I sent your message and screenshot word for word");
});

test("a one-word reply to the person's steer draws too: it answers the person", async () => {
  for (const family of FAMILIES) {
    const { drawn } = await draw(chat({ steer: "stop the deploy", reply: "Stopped." }), family);
    expect(drawnText(drawn), String(family)).toContain("Stopped.");
  }
});

test("with no steer, a finish's turn that reports something draws its report under the task's line", async () => {
  for (const family of FAMILIES) {
    const { drawn } = await draw(chat({ reply: REPORT }), family);
    expect(drawnText(drawn), String(family)).toContain("The deploy did not happen");
    expect(drawnText(drawn), String(family)).toContain("the same timed pass");
    const line = drawn.findIndex((row) => row.kind === "backgroundTurn");
    const report = drawn.findIndex((row) => row.kind === "assistant" && row.text?.startsWith("The deploy"));
    expect(line, String(family)).toBeGreaterThanOrEqual(0);
    expect(drawn[line]?.background?.cause?.weight).toBe("result");
    expect(report, String(family)).toBeGreaterThan(line);
  }
});

test("a one-line acknowledgement of a finish still draws nothing but the task's line", async () => {
  for (const family of FAMILIES) {
    const { drawn } = await draw(chat({ reply: ACK }), family);
    expect(drawnText(drawn), String(family)).not.toContain(ACK);
    expect(drawn.some((row) => row.kind === "backgroundTurn")).toBe(true);
  }
});
