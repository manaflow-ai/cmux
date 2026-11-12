// l10n-allow-file: recorded chat fixtures, not shipped UI.
// A turn's last words to the person always draw under its prompt, outside its closed "Worked for",
// and never after a later turn (Leo, 2026-11-12: "in this case you didnt respond to me at all...",
// then "even right now the coordinator's not even really responding to me"). The coordinator had
// answered (seq 2235884 of its acpmux log), then sent another agent a message in the same turn; the
// pane took the answer for narration before that call and folded it, so under the prompt it drew
// only "Worked for 27s · 1 tool call". The fixture is that turn's shape, synthetic: the prompt, a
// read, the answer streamed between subagent and task progress, a send, the result, then the
// notice-driven turn that followed.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { turnView, WORKED } from "./turns";

const ANSWER = "Sorry, that's frustrating. I did answer, but the chat drew the answer above your question.";

let seq = 0;
const event = (kind: string, dir: "mux" | "in", msg: EventRecord["msg"]): EventRecord => ({
  seq: (seq += 1),
  kind,
  dir,
  msg,
  sessionId: "coord",
  at: 1794473499000 + seq * 400,
});
const update = (kind: string, data: Record<string, unknown>) =>
  event(kind, "in", { method: "session/update", params: { update: { sessionUpdate: kind, ...data } } });
const say = (text: string) => update("agent_message_chunk", { content: { type: "text", text } });
const call = (id: string, title: string, kind = "execute") => [
  update("tool_call", { toolCallId: id, title, kind, status: "in_progress", rawInput: { command: title } }),
  update("tool_call_update", { toolCallId: id, status: "completed" }),
];
const subagent = () => update("subagent_progress", { subagentSessionId: "coord/helper", task: "Review the lane" });
const task = () => update("task_progress", { taskId: "watch-1", description: "Watch CI", status: "running" });
const prompt = (text: string) => event("user_message", "mux", { text });
const steer = (text: string) => event("user_message", "mux", { text, steer: true });
const started = () => event("turn_started", "mux", {});
const ended = () => event("turn_result", "mux", { status: "completed" });
const noticeText = "[inbox] New messages from other agents in 1 thread.\n- 1 new in #41780 from claude-sr2: Pushed.";
const notice = () =>
  event("user_message", "mux", {
    text: noticeText,
    client: "acpmux",
    _meta: {
      provenance: {
        kind: "inbox_notice",
        noticeId: `notice-${seq}`,
        threads: [
          {
            threadId: "from:claude-sr2/pr:41780",
            label: "#41780",
            new: 1,
            from: ["claude-sr2"],
            promptIds: [`m-${seq}`],
            blocker: false,
            preview: "Pushed.",
          },
        ],
      },
    },
  });

/// The rows the transcript's own reducer folds `events` into, then the chat's drawn rows.
function replay(events: EventRecord[]): AcpmuxRow[] {
  let rows: readonly AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay("coord", events, (snapshot) => {
    rows = snapshot.rows;
  });
  try {
    client.seekReplay(events.at(-1)!.seq);
  } finally {
    client.close();
  }
  return [...rows];
}
const drawn = (rows: readonly AcpmuxRow[], expanded = new Set<string>()) =>
  turnView(rows, expanded, { agentFamily: "claude" });

test("the coordinator's answer draws under Leo's prompt, beside its closed Worked for", () => {
  seq = 0;
  const events = [
    prompt("in this case you didnt respond to me at all..."),
    started(),
    subagent(),
    ...call("read-1", "Read chat.md", "read"),
    task(),
    say("Sorry, that's frustrating. "),
    subagent(),
    say("I did answer, but the chat drew "),
    task(),
    say("the answer above your question."),
    ...call("send-1", "acpmux send claude-sr2 'carryPrompts: look at turn 2235274'"),
    subagent(),
    ended(),
    notice(),
    started(),
    ...call("read-2", "inbox_read from:claude-sr2/pr:41780", "read"),
    task(),
    ...call("send-2", "acpmux send claude-sr2 'thanks'"),
    ended(),
  ];
  const view = drawn(replay(events));
  const kinds = view.map((row) => `${row.kind}:${row.text ?? ""}`);
  const asked = view.findIndex((row) => row.kind === "user" && row.text?.startsWith("in this case"));
  const answer = view.findIndex((row) => row.kind === "assistant" && row.text === ANSWER);
  const nextTurn = view.findIndex((row, at) => at > asked && row.kind === WORKED && row.foldedPrompt !== undefined);
  expect(asked, kinds.join("\n")).toBeGreaterThanOrEqual(0);
  expect(answer, kinds.join("\n")).toBeGreaterThan(asked);
  // Nothing but this turn's own fold sits between the prompt and its answer.
  expect(view.slice(asked + 1, answer).map((row) => row.kind)).toEqual([WORKED]);
  expect(nextTurn < 0 || answer < nextTurn, kinds.join("\n")).toBe(true);
  // Not inside a fold: the closed line holds it nowhere.
  expect(view[answer]!.foldedReply).toBeUndefined();
});

// The whole class: random turns of chunks, calls, subagent and task progress, the person's steers
// and notice-driven turns. Closed, each turn's last reply draws after its prompt and before the next
// turn's; opened all the way, every reply the agent wrote draws, in the order it wrote them.
function random(seed: number) {
  let state = seed >>> 0;
  return (n: number) => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state % n;
  };
}

type Turn = { opener: string; replies: string[] };

function chat(seed: number): { events: EventRecord[]; turns: Turn[] } {
  const pick = random(seed);
  seq = 0;
  const events: EventRecord[] = [];
  const turns: Turn[] = [];
  let calls = 0;
  const turnCount = 1 + pick(4);
  for (let t = 0; t < turnCount; t += 1) {
    const byNotice = t > 0 && pick(3) === 0;
    const opener = byNotice ? noticeText : `Prompt ${seed}-${t}: what changed?`;
    events.push(byNotice ? notice() : prompt(opener), started());
    const turn: Turn = { opener, replies: [] };
    turns.push(turn);
    let open = false;
    const steps = 1 + pick(10);
    for (let s = 0; s < steps; s += 1) {
      switch (pick(7)) {
        case 0:
        case 1: {
          // A reply streams in pieces, maybe with progress between them; a call or a steer ends it.
          const words = `Reply ${seed}-${t}-${s} says the fix is in.`;
          if (!open) turn.replies.push(words);
          else turn.replies[turn.replies.length - 1] += ` ${words}`;
          const cut = 1 + pick(words.length - 1);
          events.push(say(open ? ` ${words.slice(0, cut)}` : words.slice(0, cut)));
          if (pick(2)) events.push(pick(2) ? subagent() : task());
          events.push(say(words.slice(cut)));
          open = true;
          break;
        }
        case 2:
        case 3:
          events.push(...call(`call-${(calls += 1)}`, pick(2) ? "acpmux send lane 'hi'" : "bun test", "execute"));
          open = false;
          break;
        case 4:
          events.push(subagent());
          break;
        case 5:
          events.push(task());
          break;
        case 6:
          events.push(steer(`Steer ${seed}-${t}-${s}: also check CI`));
          open = false;
          break;
      }
    }
    events.push(ended());
  }
  return { events, turns };
}

/// Every fold the view draws opened, until opening finds no more.
function openedAll(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const expanded = new Set<string>();
  let view = drawn(rows, expanded);
  for (let round = 0; round < 6; round += 1) {
    const before = expanded.size;
    for (const row of view) expanded.add(row.id);
    if (expanded.size === before) break;
    view = drawn(rows, expanded);
  }
  return view;
}

/// The agent's words an opened view draws: its replies, and the short notes a run line carries as
/// its quiet lines (turns.ts `mergeShortNotes`).
const replyText = (view: readonly AcpmuxRow[]) =>
  view
    .flatMap((row) =>
      row.kind === "assistant"
        ? [row.text ?? ""]
        : (row.items ?? []).flatMap((item) => (item.kind === "note" && item.text ? [item.text] : [])),
    )
    .join("\n");

test("every turn's last reply draws under its prompt, closed, for random interleavings", () => {
  for (let seed = 1; seed <= 400; seed += 1) {
    const { events, turns } = chat(seed);
    const rows = replay(events);
    const closed = drawn(rows);
    const text = closed.map((row) => `${row.kind}:${(row.text ?? "").slice(0, 60)}`).join("\n");
    let floor = -1;
    for (const turn of turns) {
      const last = turn.replies.at(-1);
      if (last === undefined) continue;
      const at = closed.findIndex(
        (row, index) => index > floor && row.kind === "assistant" && (row.text ?? "").includes(last),
      );
      expect(at, `seed ${seed}: "${last}" not drawn after the turn before it\n${text}`).toBeGreaterThan(floor);
      expect(closed[at]!.foldedReply, `seed ${seed}: "${last}" drawn inside a fold`).toBeUndefined();
      floor = at;
    }
  }
});

test("every reply draws, in order, once the folds open, for random interleavings", () => {
  for (let seed = 1; seed <= 400; seed += 1) {
    const { events, turns } = chat(seed);
    const all = replyText(openedAll(replay(events)));
    let from = 0;
    for (const words of turns.flatMap((turn) => turn.replies)) {
      const at = all.indexOf(words, from);
      expect(at, `seed ${seed}: "${words}" missing or out of order\n${all}`).toBeGreaterThanOrEqual(0);
      from = at + words.length;
    }
  }
});
