// l10n-allow-file: recorded chat fixtures, not shipped UI.
// The agent's replies to the person always draw, in order, under the prompt or steer they answer
// (Leo, 2026-11-12: "in this case you didnt respond to me at all...", then "even right now the
// coordinator's not even really responding to me"). The coordinator had answered both messages;
// the chat drew his steer under the answer to it (liveSteerOrder.test.ts has that live path).
// These replay the transcript's own reducer: the incident's turn shapes (a reply streamed between
// subagent and task progress, then a send; the 07:51Z turn as logged, its answer between its send
// and its helpers' work) and the whole class over random interleavings. Short notes before more
// work stay status and fold, as transcript-worked-fold.test.ts settles; they draw once opened.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { turnView, WORKED } from "./turns";

const ANSWER =
  "Sorry, that's frustrating. I did answer, but the chat drew the answer above your question, so it looked like I ignored you.\n\nMy answer was **no**, it shouldn't say cmux.";

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
  event(kind, "in", {
    method: "session/update",
    params: { update: { sessionUpdate: kind, ...data } },
  });
const say = (text: string, messageId?: string) =>
  update("agent_message_chunk", {
    content: { type: "text", text },
    ...(messageId ? { messageId } : {}),
  });
const call = (id: string, title: string, kind = "execute") => [
  update("tool_call", {
    toolCallId: id,
    title,
    kind,
    status: "in_progress",
    rawInput: { command: title },
  }),
  update("tool_call_update", { toolCallId: id, status: "completed" }),
];
const subagent = () =>
  update("subagent_progress", {
    subagentSessionId: "coord/helper",
    task: "Review the lane",
  });
const task = () =>
  update("task_progress", {
    taskId: "watch-1",
    description: "Watch CI",
    status: "running",
  });
const prompt = (text: string) => event("user_message", "mux", { text });
const steer = (text: string, promptId?: string) =>
  event("user_message", "mux", {
    text,
    steer: true,
    ...(promptId ? { promptId } : {}),
  });
const steerRead = (promptId: string) => event("steer_read", "mux", { promptId });
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

test("an answer the agent followed with a send draws under the prompt, beside its closed Worked for", () => {
  seq = 0;
  const events = [
    prompt("in this case you didnt respond to me at all..."),
    started(),
    subagent(),
    ...call("read-1", "Read chat.md", "read"),
    task(),
    say("Sorry, that's frustrating. I did answer, but the chat drew the answer above your question, "),
    subagent(),
    say("so it looked like I ignored you.\n\n"),
    task(),
    say("My answer was **no**, it shouldn't say cmux."),
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

/// An update one of the chat's helpers made, tagged with it (acpmux `_meta.acpmux.subagent`).
const helper = (id: string, kind: string, data: Record<string, unknown>) =>
  event(kind, "in", {
    method: "session/update",
    params: {
      _meta: { acpmux: { subagent: `coord/${id}` } },
      sessionId: `coord/${id}`,
      update: { sessionUpdate: kind, ...data },
    },
  });
const progress = (id: string, parent: string | null) =>
  event("subagent_progress", "in", {
    method: "session/update",
    params: {
      _meta: {
        acpmux: {
          subagents: [
            {
              id: `coord/${id}`,
              name: id,
              parent: parent && `coord/${parent}`,
              state: "running",
            },
          ],
        },
      },
      sessionId: "coord",
      update: {
        sessionUpdate: "subagent_progress",
        subagentSessionId: `coord/${id}`,
      },
    },
  });

test("the coordinator's 07:51Z turn draws its answer under Leo's prompt, as logged", () => {
  seq = 0;
  const spawn = (id: string) =>
    update("tool_call", {
      toolCallId: id,
      title: id,
      kind: "think",
      status: "in_progress",
      _meta: { claude: { tool: "Agent" } },
    });
  const events = [
    prompt("Look into the deploys"),
    started(),
    spawn("deploys"),
    spawn("customize"),
    say("Started two helpers."),
    ended(),
    prompt("in this case you didnt respond to me at all..."),
    started(),
    progress("inventory", "customize"),
    ...call("send-1", "send_message", "other"),
    progress("inventory", "customize"),
    helper("deploys", "agent_thought_chunk", {
      content: { type: "text", text: "Reading ws-deploy" },
    }),
    ...ANSWER.split(/(?<= )/).map(say),
    progress("inventory", "customize"),
    helper("deploys", "tool_call", {
      toolCallId: "read-9",
      title: "Read ws-deploy",
      kind: "execute",
      status: "in_progress",
    }),
    progress("deploys", null),
    helper("inventory", "tool_call_update", {
      toolCallId: "grep-3",
      status: "completed",
    }),
    helper("customize", "tool_call_update", {
      toolCallId: "read-4",
      status: "completed",
    }),
    event("turn_end", "mux", { stopReason: "end_turn" }),
    ended(),
  ];
  const view = drawn(replay(events));
  const kinds = view.map((row) => `${row.kind}:${row.text ?? ""}`).join("\n");
  const asked = view.findIndex((row) => row.kind === "user" && row.text?.startsWith("in this case"));
  const answer = view.findIndex((row) => row.kind === "assistant" && row.text === ANSWER);
  expect(answer, kinds).toBeGreaterThan(asked);
  expect(
    view.slice(asked + 1, answer).map((row) => row.kind),
    kinds,
  ).toEqual([WORKED]);
});

test("opened, a steered turn's answer stays above the steer it came before", () => {
  seq = 0;
  const events = [
    prompt("What changed?"),
    started(),
    ...call("c1", "bun test"),
    say(ANSWER, "m1"),
    steer("Also check CI", "p1"),
    steerRead("p1"),
    ...call("c2", "acpmux send lane 'hi'"),
    say("Checking.", "m2"),
    ...call("c3", "bun test"),
    ended(),
  ];
  const rows = replay(events);
  for (const view of [drawn(rows), openedAll(rows)]) {
    const kinds = view.map((row) => `${row.kind}:${(row.text ?? "").slice(0, 20)}`);
    const answer = view.findIndex((row) => row.kind === "assistant" && row.text === ANSWER);
    const steered = view.findIndex((row) => row.kind === "user" && row.text === "Also check CI");
    expect(answer, kinds.join("\n")).toBeGreaterThan(0);
    expect(answer < steered, kinds.join("\n")).toBe(true);
  }
});

// The whole class: random turns of chunks, calls, subagent and task progress, the person's steers
// and notice-driven turns. Closed, every reply to the person draws in order and outside the fold;
// opened all the way, every word the agent wrote draws, in the order it wrote them.
function random(seed: number) {
  let state = seed >>> 0;
  return (n: number) => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state % n;
  };
}

/// What the agent wrote between two of the person's messages (a prompt, a steer or a notice), and
/// whether each piece reads as a reply to the person (turns.ts `isTakeaway`) rather than a short
/// note before more work.
/// `stepped`: a call came after its last reply. `steered`: the person's steer ended it.
type Stretch = {
  replies: string[];
  takeaways: boolean[];
  stepped: boolean;
  steered?: boolean;
};

function chat(seed: number): { events: EventRecord[]; stretches: Stretch[] } {
  const pick = random(seed);
  seq = 0;
  const events: EventRecord[] = [];
  const stretches: Stretch[] = [];
  let calls = 0;
  const turnCount = 1 + pick(4);
  for (let t = 0; t < turnCount; t += 1) {
    const byNotice = t > 0 && pick(3) === 0;
    const opener = byNotice ? noticeText : `Prompt ${seed}-${t}: what changed?`;
    events.push(byNotice ? notice() : prompt(opener), started());
    let turn: Stretch = { replies: [], takeaways: [], stepped: false };
    stretches.push(turn);
    let open = false;
    let message = "";
    const steps = 1 + pick(10);
    for (let s = 0; s < steps; s += 1) {
      switch (pick(7)) {
        case 0:
        case 1: {
          // A reply streams in pieces, maybe with progress between them; a call or a steer ends it.
          const full = pick(2) === 0;
          const words = full
            ? `Reply ${seed}-${t}-${s}: the fix is in.\n\nCI is green at its head.`
            : `Note ${seed}-${t}-${s}: checking.`;
          turn.stepped = false;
          if (!open) {
            message = `msg-${seed}-${t}-${s}`;
            turn.replies.push(words);
            turn.takeaways.push(full);
          } else {
            turn.replies[turn.replies.length - 1] += ` ${words}`;
            turn.takeaways[turn.takeaways.length - 1] ||= full;
          }
          const cut = 1 + pick(words.length - 1);
          events.push(say(open ? ` ${words.slice(0, cut)}` : words.slice(0, cut), message));
          if (pick(2)) events.push(pick(2) ? subagent() : task());
          events.push(say(words.slice(cut), message));
          open = true;
          break;
        }
        case 2:
        case 3:
          events.push(...call(`call-${(calls += 1)}`, pick(2) ? "acpmux send lane 'hi'" : "bun test", "execute"));
          turn.stepped = true;
          open = false;
          break;
        case 4:
          events.push(subagent());
          break;
        case 5:
          events.push(task());
          break;
        case 6:
          // A steer lands at the agent's next step (acpmux `steer_end.rs`); what it writes after is a
          // new message.
          events.push(steer(`Steer ${seed}-${t}-${s}: also check CI`, `p-${seed}-${t}-${s}`));
          events.push(steerRead(`p-${seed}-${t}-${s}`));
          turn.steered = true;
          turn = { replies: [], takeaways: [], stepped: false };
          stretches.push(turn);
          open = false;
          break;
      }
    }
    events.push(ended());
  }
  return { events, stretches };
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

test("each answer to the person draws closed, in order, never in a fold, for random interleavings", () => {
  for (let seed = 1; seed <= 400; seed += 1) {
    const { events, stretches } = chat(seed);
    const closed = drawn(replay(events));
    const text = closed.map((row) => `${row.kind}:${(row.text ?? "").slice(0, 60)}`).join("\n");
    let floor = -1;
    for (const stretch of stretches) {
      // The stretch's answer is its last words when the person steered after them or no step came
      // after them (turns.ts `steerDialogueIn`), else its last reply to the person; notes and work
      // after that fold above it (`answerAt`).
      const words =
        stretch.stepped && !stretch.steered
          ? stretch.replies.findLast((_, index) => stretch.takeaways[index])
          : stretch.replies.at(-1);
      if (words === undefined) continue;
      const at = closed.findIndex(
        (row, drawnAt) => drawnAt > floor && row.kind === "assistant" && (row.text ?? "").includes(words),
      );
      expect(at, `seed ${seed}: "${words}" not drawn, or drawn out of order\n${text}`).toBeGreaterThan(floor);
      expect(closed[at]!.foldedReply, `seed ${seed}: "${words}" drawn inside a fold`).toBeUndefined();
      floor = at;
    }
  }
});

test("every reply draws once the folds open, each stretch's after the one before, for random interleavings", () => {
  for (let seed = 1; seed <= 400; seed += 1) {
    const { events, stretches } = chat(seed);
    const all = replyText(openedAll(replay(events)));
    let floor = 0;
    for (const stretch of stretches) {
      // Within a stretch the fold draws above its answer, so only the stretches keep their order.
      let end = floor;
      for (const words of stretch.replies) {
        const at = all.indexOf(words, floor);
        expect(at, `seed ${seed}: "${words}" missing or out of order\n${all}`).toBeGreaterThanOrEqual(0);
        end = Math.max(end, at + words.length);
      }
      floor = end;
    }
  }
});
