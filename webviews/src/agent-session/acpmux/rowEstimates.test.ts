// l10n-allow-file: test fixture replies, not shipped UI.
// The virtualizer's first-layout estimates (model.ts layoutConversation) match what the transcript's
// CSS draws (conversation/conversation.css, styles.css), so a row that mounts moves nothing below it
// and scrolling up never jumps:
//   - a reply right over its turn's footer (`.acpmux-row--before-footer`), or over the running turn's
//     line that the footer takes the place of: its text and the 4px meta gap, with no 34px floor;
//   - a task's result (`.cv-received`): its 26px line and the 8px message gap;
//   - another agent's message: its one disclosure line, however long the message;
//   - a reply's footer: its 32 line of buttons (ChatGPT's), 8 under the reply, including the chat's
//     last one (`.acpmux-row--last-footer`); the running turn's line under a reply takes that slot.
//
// Before: a reply over a footer was estimated as any reply (8px below it, at least 34px), and a
// task's result kept the old 16px below it.
import { expect, test } from "bun:test";
import {
  codeCardHeight,
  hasReplyActions,
  keepsReplyRoom,
  layoutConversation,
  placeRows,
  statusEdge,
  type AcpmuxRow,
} from "./model";
import { turnView } from "./conversation/turns";
import { COLLAPSED_PROMPT_LINES, PASTE_CHIP_HEIGHT, PROMPT_MORE_HEIGHT } from "./conversation/promptCollapse";
import { currentChatMetrics } from "./chatDisplay";
import { gridLength, TRANSCRIPT_FOOTER_CONTROL } from "./transcriptGrid";

const reply = (id: string, text: string) => ({ id, version: 1, at: 0, kind: "assistant", text });
// A footer carries its answer's text, for Copy (conversation/turns.ts), so the estimate never reads it.
const footer = (id: string) => ({
  id,
  version: 1,
  at: 0,
  kind: "turnSummary",
  status: "completed",
  text: "An answer long enough to wrap onto many lines. ".repeat(30),
});
const prompt = (id: string) => ({ id, version: 1, at: 0, kind: "user", text: "Next" });
const heightsOf = (rows: unknown[]) => [...layoutConversation(rows as never, 720).heights];

test("a reply over its footer is its text alone, with no 34px floor", () => {
  const long = "A longer answer that wraps. ".repeat(40);
  const [alone] = heightsOf([reply("a", long)]);
  const [over, summary] = heightsOf([reply("a", long), footer("f"), prompt("p")]);
  // The same text: 8px below it alone, 4px over its footer.
  expect(alone! - over!).toBeCloseTo(0, 5);
  // The footer is its 32 line of buttons, including the last one.
  expect(summary).toBe(TRANSCRIPT_FOOTER_CONTROL);
  expect(heightsOf([reply("a", long), footer("f")])[1]).toBe(TRANSCRIPT_FOOTER_CONTROL);
  // A one-line reply over its footer is shorter than a row's 34px floor.
  const [short] = heightsOf([reply("b", "Done."), footer("g")]);
  expect(short!).toBeLessThan(34);
  expect(short! - 4).toBeGreaterThan(0);
});

test("a reply over its running turn's line is estimated as over the footer that takes its place", () => {
  const long = "A longer answer that wraps. ".repeat(40);
  // The running turn's line as its last row (conversation/turns.ts `below`): the footer's height.
  const line = { id: "live", version: 1, at: 0, kind: "thinking", below: true };
  const live = layoutConversation([reply("a", long), line] as never, 720);
  const ended = layoutConversation([reply("a", long), footer("f")] as never, 720);
  // The turn's end swaps the line for the footer and moves nothing: same place, same height, same tail.
  expect(live.heights[1]).toBe(TRANSCRIPT_FOOTER_CONTROL);
  expect(ended.heights[1]).toBe(TRANSCRIPT_FOOTER_CONTROL);
  expect(live.heights[0]).toBe(ended.heights[0]);
  expect(live.tops[1]).toBe(ended.tops[1]);
  expect(live.totalHeight + (live.tailGap ?? 0)).toBe(ended.totalHeight + (ended.tailGap ?? 0));
});

test("a reply estimated alone, then with its footer after it, is estimated again", () => {
  const rows = [reply("a", "Done.")];
  const first = layoutConversation(rows as never, 720);
  expect(first.heights[0]).toBe(currentChatMetrics().lineHeight);
  const next = [...rows, footer("f")];
  const second = layoutConversation(next as never, 720, undefined, undefined, undefined, {
    rows,
    layout: first,
  });
  expect(second.heights[0]).toBeLessThan(34);
  expect(second.tops[1]).toBe(second.heights[0]! + gridLength("gap-footer"));
});

test("a live footer slot keeps short, long, and tool-ending turns at the settled height", () => {
  for (const text of ["Done.", "A longer answer that wraps. ".repeat(40)]) {
    const source = [
      { id: "u", version: 1, at: 1_000, kind: "user", text: "Go" },
      { id: "a", version: 1, at: 2_000, kind: "assistant", text },
    ];
    const live = turnView(source as never, new Set(), {
      now: 3_000,
      working: true,
      lineBelow: true,
      liveRuns: true,
      sessionStatus: true,
    });
    const settled = turnView(
      [...source, { id: "s", version: 1, at: 3_000, kind: "turnSummary", status: "completed", text }] as never,
      new Set(),
      { now: 4_000, lineBelow: true, liveRuns: true, sessionStatus: true },
    );
    expect(live.at(-1)).toMatchObject({ below: true });
    expect(settled.at(-1)).toMatchObject({ kind: "turnSummary" });
    const [running, ended] = [layoutConversation(live, 720), layoutConversation(settled, 720)];
    expect(running.heights.at(-1)).toBe(TRANSCRIPT_FOOTER_CONTROL);
    expect(ended.heights.at(-1)).toBe(TRANSCRIPT_FOOTER_CONTROL);
    expect(running.tops.at(-1)).toBe(ended.tops.at(-1));
  }

  const liveSource = [
    { id: "u", version: 1, at: 1_000, kind: "user", text: "Run it" },
    { id: "a", version: 1, at: 2_000, kind: "assistant", text: "The command is ready." },
    { id: "p", version: 1, at: 3_000, kind: "plan", plan: [{ content: "Run", status: "in_progress" }] },
    {
      id: "t",
      version: 1,
      at: 4_000,
      kind: "activity",
      items: [{ kind: "tool", text: "", tool: { id: "call", title: "Run", kind: "execute", status: "in_progress" } }],
    },
  ];
  const live = turnView(liveSource as never, new Set(), {
    now: 5_000,
    working: true,
    lineBelow: true,
    liveRuns: true,
    sessionStatus: true,
  });
  const settledSource = [
    ...liveSource.slice(0, -1),
    {
      ...liveSource.at(-1)!,
      items: [{ kind: "tool", text: "", tool: { id: "call", title: "Run", kind: "execute", status: "completed" } }],
    },
    { id: "s", version: 1, at: 5_000, kind: "turnSummary", status: "completed", text: "The command is ready." },
  ];
  const settled = turnView(settledSource as never, new Set(), {
    now: 6_000,
    lineBelow: true,
    liveRuns: true,
    sessionStatus: true,
  });
  expect(live.at(-1)).toMatchObject({ kind: "activityLine", below: true });
  expect(settled.at(-1)).toMatchObject({ kind: "turnSummary" });
  expect(layoutConversation(live, 720).heights.at(-1)).toBe(TRANSCRIPT_FOOTER_CONTROL);
  expect(layoutConversation(settled, 720).heights.at(-1)).toBe(TRANSCRIPT_FOOTER_CONTROL);

  const legacy = turnView(liveSource as never, new Set(), {
    now: 5_000,
    working: true,
    lineBelow: false,
    liveRuns: false,
    sessionStatus: true,
  });
  expect(legacy.at(-1)).toMatchObject({ kind: "activityLine" });
  expect(legacy.at(-1)?.below).toBeUndefined();
  expect(layoutConversation(legacy, 720).heights.at(-1)).toBe(28);
});

test("the chat's last footer is placed again when a prompt follows it", () => {
  const rows = [reply("a", "Done."), footer("f")];
  const first = layoutConversation(rows as never, 720);
  expect(first.heights[1]).toBe(TRANSCRIPT_FOOTER_CONTROL);
  const second = layoutConversation([...rows, prompt("p")] as never, 720, undefined, undefined, undefined, {
    rows,
    layout: first,
  });
  expect(second).toEqual(layoutConversation([...rows, prompt("p")] as never, 720));
});

test("a footer over another agent's line or a task's result has the block gap under it, a prompt the turn gap", () => {
  const result = { id: "r", version: 1, at: 0, kind: "user", text: "Done", received: { offerId: "o", title: "Tests" } };
  const message = {
    id: "m",
    version: 1,
    at: 0,
    kind: "user",
    text: "Not idle.",
    incoming: { kind: "message", message: { name: "deputy-2", text: "Not idle.", raw: "Not idle." } },
  };
  const notice = { id: "n", version: 1, at: 0, kind: "user", text: "Done", incoming: { kind: "notice", text: "Done" } };
  for (const line of [result, message, notice]) {
    const layout = layoutConversation([reply("a", "Done."), footer("f"), line] as never, 720);
    expect(layout.tops[2]! - layout.tops[1]! - layout.heights[1]!).toBe(gridLength("gap-block"));
  }
  // The person's prompt after it still starts a turn of its own.
  const turn = layoutConversation([reply("a", "Done."), footer("f"), prompt("p")] as never, 720);
  expect(turn.tops[2]! - turn.tops[1]! - turn.heights[1]!).toBe(gridLength("gap-turn"));
});

test("a task's result is its 26px line and the 8px message gap", () => {
  const [height] = heightsOf([
    { id: "r", version: 1, at: 0, kind: "user", text: "Run the tests", received: { offerId: "o", title: "Tests" } },
  ]);
  expect(height).toBe(28);
});

test("a footer shaped by turnView, which carries its answer's text, is its 32 line", () => {
  const answer = "A longer answer that wraps. ".repeat(40);
  const source = [
    { id: "u1", version: 1, at: 1_000, kind: "user", text: "First" },
    { id: "a1", version: 1, at: 2_000, kind: "assistant", text: answer },
    { id: "s1", version: 1, at: 3_000, kind: "turnSummary", status: "completed", durationMs: 2_000 },
    { id: "u2", version: 1, at: 4_000, kind: "user", text: "Second" },
    { id: "a2", version: 1, at: 5_000, kind: "assistant", text: answer },
    { id: "s2", version: 1, at: 6_000, kind: "turnSummary", status: "completed", durationMs: 2_000 },
  ];
  const rows = turnView(source as never, new Set(), { now: 7_000 });
  const footers = rows.flatMap((row, index) => (row.kind === "turnSummary" ? [index] : []));
  expect(footers.length).toBe(2);
  expect(rows[footers[0]!]!.text).toBe(answer);
  const { heights } = layoutConversation(rows, 720);
  expect(heights[footers[0]!]).toBe(TRANSCRIPT_FOOTER_CONTROL);
  expect(heights[footers[1]!]).toBe(TRANSCRIPT_FOOTER_CONTROL);
});

test("a latest history turn without a summary keeps the turn gap at the composer", () => {
  const rows = turnView(
    [
      { id: "u", version: 1, at: 1_000, kind: "user", text: "First" },
      { id: "a", version: 1, at: 2_000, kind: "assistant", text: "Done." },
    ] as never,
    new Set(),
    { now: 3_000 },
  );
  const final = rows.at(-1)!;
  expect(final.kind).toBe("assistant");
  expect(final.lastTurn).toBe(true);
  const { heights } = layoutConversation(rows, 720);
  // The terminal assistant has the same 16px bottom rhythm as a footer, without a row underneath.
  expect(heights.at(-1)).toBe(currentChatMetrics().lineHeight);
});

test("specialized latest rows reserve the same no-summary turn gap before mounting", () => {
  const sources = [
    [
      { id: "u", version: 1, at: 1_000, kind: "user", text: "Run it" },
      {
        id: "tool",
        version: 1,
        at: 2_000,
        kind: "activity",
        items: [{ kind: "execute", text: "Running", tool: { id: "call", title: "Run", status: "completed" } }],
      },
    ],
    [
      { id: "u", version: 1, at: 1_000, kind: "user", text: "Wait" },
      { id: "notice", version: 1, at: 2_000, kind: "notice" },
    ],
    [
      { id: "u", version: 1, at: 1_000, kind: "user", text: "Think" },
      { id: "quiet", version: 1, at: 2_000, kind: "activity", items: [{ kind: "thought", text: "brief" }] },
    ],
  ];
  for (const source of sources) {
    const rows = turnView(source as never, new Set(), { now: 3_000 });
    const final = rows.at(-1)!;
    expect(final.lastTurn).toBe(true);
    const withGap = layoutConversation(rows, 720).heights.at(-1)!;
    const withoutMarker = layoutConversation(
      rows.map(({ lastTurn: _lastTurn, ...row }) => row),
      720,
    ).heights.at(-1)!;
    if (final.items?.[0]?.kind === "thought") expect(withGap).toBe(0);
    else if (final.kind === "activity") expect(withGap - withoutMarker).toBe(0);
    else expect(withGap - withoutMarker).toBe(0);
  }
});

test("a hidden row after the chat's last footer leaves it the last one", () => {
  const hidden = { id: "h", version: 1, at: 0, kind: "user", text: "", incoming: { kind: "hidden" } };
  const layout = layoutConversation([reply("a", "Done."), footer("f"), hidden] as never, 720);
  expect(layout.heights[1]).toBe(TRANSCRIPT_FOOTER_CONTROL);
  expect(layout.heights[2]).toBe(0);
  expect(layout.tailGap).toBe(gridLength("gap-block"));
});

// Every one-line row takes a one-call tool run's frame: 2px over the 22px tool line, the 4px run gap
// under it (model.ts LINE_ROW, conversation.css `.acpmux-row--line`).
test("another agent's message is one 22px tool line in the one-line rows' frame, however long", () => {
  const row = (id: string, text: string) => ({
    id,
    version: 1,
    at: 0,
    kind: "user",
    text,
    incoming: { kind: "message", message: { name: "cmux16/glass-lens", text, raw: text } },
  });
  const [short, long] = heightsOf([row("m1", "Draft is up."), row("m2", "Line of the report.\n".repeat(40))]);
  expect(short).toBe(22);
  expect(long).toBe(short);
});

test("a message this agent sent another one is one 22px tool line in the one-line rows' frame", () => {
  const send = {
    kind: "tool",
    text: "SendMessage",
    tool: {
      id: "send",
      title: "SendMessage",
      kind: "other",
      status: "completed",
      inputSummary: JSON.stringify({ to: "gcp-a-lane", message: "Rebase, then land." }),
    },
  };
  const [height] = heightsOf([{ id: "s", version: 1, at: 0, kind: "activity", items: [send] }]);
  expect(height).toBe(22);
});

test("a task notice is a tool row's line in the one-line rows' frame", () => {
  const [height] = heightsOf([
    { id: "n", version: 1, at: 0, kind: "user", text: "Task done", incoming: { kind: "notice", text: "Task done" } },
  ]);
  expect(height).toBe(22);
});

// A waiting steer's Send now leads the existing action row, so it adds no height to a text prompt.
test("a steer the agent has not read is as tall as a read one: its Send now leads the action row", () => {
  const steer = (state: string) => ({ id: "s", version: 1, at: 0, kind: "user", text: "Also this", steer: state });
  const [landed] = heightsOf([steer("landed")]);
  const [waiting] = heightsOf([steer("waiting")]);
  expect(waiting).toBe(landed! + 28);
});

test("a Chief's waiting steer keeps Send now in its existing action row", () => {
  const steer = (state: string) => ({
    id: "s",
    version: 1,
    at: 0,
    kind: "user",
    text: "Also this",
    from: "chief",
    steer: state,
  });
  const [landed] = heightsOf([steer("landed")]);
  const [waiting] = heightsOf([steer("waiting")]);
  expect(waiting!).toBe(landed!);
});

// A long prompt opens collapsed (conversation/UserBubble.tsx, promptCollapse.ts): its first ten
// lines over the 24px Show more line, inside the bubble's 16px of padding, with its 28px hover row
// under it and the 8px message gap. Estimated any taller, the row shrinks once drawn and the
// rows below jump up.
// Before: a prompt was estimated at its whole text, 2,000 lines tall.
test("a 2,000-line prompt is estimated at its collapsed height, at most ten lines", () => {
  const { lineHeight } = currentChatMetrics();
  const text = Array.from({ length: 2000 }, (_, index) => `line ${index + 1}`).join("\n");
  const [long] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text }]);
  expect(long).toBeCloseTo(16 + COLLAPSED_PROMPT_LINES * lineHeight + PROMPT_MORE_HEIGHT, 5);
  expect(long!).toBeLessThan(16 + 10.5 * lineHeight + 24 + 28 + 8);
});

test("a prompt of ten lines or fewer is estimated whole, with no Show more line", () => {
  const { lineHeight } = currentChatMetrics();
  const text = Array.from({ length: 3 }, (_, index) => `line ${index + 1}`).join("\n\n");
  const [short] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text }]);
  expect(short!).toBeLessThan(16 + COLLAPSED_PROMPT_LINES * lineHeight + 28 + 8);
});

// A pasted block (`pasted` ranges, the chip in UserBubble.tsx) is one chip line, however long the
// paste, and the prompt's own words around it.
test("a prompt with a 2,300-line paste is its typed line and one chip", () => {
  const { lineHeight } = currentChatMetrics();
  const typed = "Why does this fail?";
  const paste = Array.from({ length: 2300 }, (_, index) => `frame ${index}`).join("\n");
  const text = `${typed}\n${paste}`;
  const pasted = [{ start: typed.length + 1, end: text.length }];
  const [height] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text, pasted }]);
  expect(height).toBeCloseTo(16 + lineHeight + PASTE_CHIP_HEIGHT, 5);
});

// A finished step of only quiet thoughts draws nothing (conversation/ThoughtRow.tsx), so it is
// estimated at 0, and a row drawn at 0 is placed at 0. Before: 10px and 26px per thought, kept as
// blank space even after the row mounted, since a drawn 0 was read as "not laid out" (Leo,
// 2026-10-21: a screen-tall gap under an opened "Worked for").
test("a step of only quiet thoughts takes no room, estimated or drawn", () => {
  const quiet = { kind: "thought", text: "ok", startedAt: 0, endedAt: 5 };
  const step = { id: "a", version: 1, at: 0, kind: "activity", items: [quiet, quiet, quiet, quiet, quiet, quiet] };
  const [estimated] = heightsOf([step]);
  expect(estimated).toBe(0);
  // Its latest thought may still stream while the turn runs; a long one draws its row.
  expect(heightsOf([{ ...step, live: true }])[0]!).toBeGreaterThan(0);
  const long = {
    kind: "thought",
    text: "Reading the batch script before running it, step by step.",
    startedAt: 0,
    endedAt: 4_000,
  };
  expect(heightsOf([{ ...step, items: [quiet, long] }])[0]!).toBeGreaterThan(0);

  const tool = {
    kind: "tool",
    text: "",
    tool: { id: "c", title: "ls", kind: "execute", status: "completed", command: "ls" },
  };
  const run = { id: "b", version: 1, at: 0, kind: "activity", items: [tool, tool, tool, tool, tool, tool] };
  const reply = { id: "r", version: 1, at: 0, kind: "assistant", text: "Done." };
  const estimate = layoutConversation([run, reply] as never, 720);
  // The run's renderer drew nothing (a render update, a payload that never came): the reply sits right under it.
  const placed = placeRows(estimate, (index) => (index === 0 ? 0 : undefined));
  expect(placed.heights[0]).toBe(0);
  expect(placed.tops[1]).toBe(0);
});

test("a status row between two replies is estimated under the reply's kept room", () => {
  // Leo, 2026-10-30: "see how claude code has those centered tool calls / id like more alignment too".
  // The reply over the run ends at its action row (its 4px meta gap and 24px line, no message gap);
  // the run (2px over its 22px row) ends 30px over the next reply, the action row's room and the
  // run's 2px top margin (conversation.css --cv-status-gap).
  const tool = {
    kind: "tool",
    text: "",
    tool: { id: "c", title: "ls", kind: "execute", status: "completed", command: "ls" },
  };
  const before = { id: "r1", version: 1, at: 0, kind: "assistant", text: "Done." };
  const run = { id: "b", version: 1, at: 1, kind: "activity", items: [tool] };
  const after = { id: "r2", version: 1, at: 2, kind: "assistant", text: "Then this." };
  const [reply, step] = heightsOf([before, run, after]);
  const [alone] = heightsOf([before]);
  const [overPrompt] = heightsOf([before, { id: "p", version: 1, at: 1, kind: "user", text: "Next" }]);
  if (hasReplyActions(before as AcpmuxRow, run as AcpmuxRow)) {
    expect(step).toBe(2 + 22 + 30);
    // The same reply over a prompt: its own action row, then the message gap.
    expect(reply).toBe(overPrompt! - 8);
  } else {
    // No reply draws its own action row (a turn's copy lives in its footer). On the grid (grid.md
    // 5.5) the stack's block gap above and below the run centres it, so neither row adds room: the
    // run is its one 22 line (design/chat-transcript.md "One-line row pitch") and the reply is as tall
    // as it is over a prompt.
    expect(step).toBe(22);
    expect(reply).toBe(overPrompt!);
  }
  expect(alone).toBeGreaterThan(0);
});

test("a status row under a prompt keeps its own spacing over the reply", () => {
  // Only a status row between two replies takes the centred room: a turn that starts with a tool
  // (prompt, tool, reply) would otherwise get 30px under the tool and its prompt gap over it.
  const tool = {
    kind: "tool",
    text: "",
    tool: { id: "c", title: "ls", kind: "execute", status: "completed", command: "ls" },
  };
  const prompt = { id: "p", version: 1, at: 0, kind: "user", text: "List it." };
  const run = { id: "b", version: 1, at: 1, kind: "activity", items: [tool] };
  const after = { id: "r2", version: 1, at: 2, kind: "assistant", text: "Then this." };
  const [, step] = heightsOf([prompt, run, after]);
  const [, alone] = heightsOf([prompt, run]);
  expect(step).toBe(alone);
  expect(statusEdge(run as AcpmuxRow, after as AcpmuxRow, prompt as AcpmuxRow)).toBeUndefined();
  // Between two replies the room under the run is read from the reply above, as the room over it
  // is, so the two match whatever the reply below is (a folded copy, a settled one).
  const reply = { id: "r1", version: 1, at: 0, kind: "assistant", text: "Done." } as AcpmuxRow;
  const over = statusEdge(reply, run as AcpmuxRow, undefined);
  const under = over === "before-status" ? "before-reply" : "before-reply-plain";
  for (const below of [after, { ...after, settled: true }, { ...after, settled: true, foldedReply: true }])
    expect(statusEdge(run as AcpmuxRow, below as AcpmuxRow, reply)).toBe(under);
});

// Leo, 2026-10-25: "when I'm seeing all of these agent messages back and forth, that's when it
// sort of, like, gets confused ... trying to scroll down slowly as you're streaming in text output".
// A folded run (the Codex-style runs, on by default) keeps every message it sent another agent in
// sight (TurnRows.tsx `runStretches`): the work around each send folds under its own summary line,
// and each send is its own 22px tool row (SentMessageLine.tsx; its Copy slot stays inside the line,
// conversation.css `.cv-sent .cv-sent-actions`). The run is estimated as those lines in its 2px top
// margin and 4px run gap, the heights Chromium draws for the same rows. Before, any folded run of
// two or more calls was estimated as one 28px summary line, so a run with sends grew by 22px a line
// when it mounted, and a sub-session `send_message` was estimated at 40px.
test("a folded run with messages to other agents is estimated as the lines it draws", () => {
  const shell = (id: string, command: string) => ({
    kind: "tool",
    text: "Bash",
    tool: { id, title: "Bash", kind: "execute", status: "completed", command, output: "queued" },
  });
  const read = { kind: "tool", text: "Read", tool: { id: "r", title: "Read a", kind: "read", status: "completed" } };
  const sendMessage = {
    kind: "tool",
    text: "mcp__cmux-subsessions__send_message",
    tool: {
      id: "m",
      title: "mcp__cmux-subsessions__send_message",
      status: "completed",
      inputSummary: JSON.stringify({ sessionId: "child-1", text: "Run the tests." }),
      output: JSON.stringify({ delivery: "queued" }),
    },
  };
  const send = (id: string, to: string) => shell(id, `acpmux send --no-wait ${to} 'Status?'`);
  const run = (items: unknown[]) => [
    { id: "run", version: 1, at: 0, kind: "activity", settled: true, foldRun: true, items },
  ];
  // A run adds no margin of its own (grid.md 5.5): its lines are flush 22px lines, one apart top to top
  // (design/chat-transcript.md "One-line row pitch", #29965).
  const lines = (n: number) => n * 22;
  // Plain work still folds to its one summary line.
  expect(heightsOf(run([shell("a", "git status"), read]))[0]).toBe(lines(1));
  // A send between two commands: a line each.
  expect(heightsOf(run([shell("a", "git status"), send("b", "lane-b"), shell("c", "cat x")]))[0]).toBe(lines(3));
  // Two sends, as two calls or as one shell batch.
  expect(heightsOf(run([send("a", "lane-a"), send("b", "lane-b")]))[0]).toBe(lines(2));
  expect(heightsOf(run([shell("a", "acpmux send --no-wait lane-a 'a'; acpmux send --no-wait lane-b 'b'")]))[0]).toBe(
    lines(2),
  );
  // Work folded on each side of the sends: "Ran 2 commands", the send, the fold of the rest, the
  // sub-session message.
  const mixed = [shell("a", "ls"), shell("b", "cat y"), send("s", "lane-a"), shell("d", "git diff"), read, sendMessage];
  expect(heightsOf(run(mixed))[0]).toBe(lines(4));
  // A sub-session message alone is one tool row, folded or not.
  expect(heightsOf(run([sendMessage]))[0]).toBe(lines(1));
  expect(heightsOf([{ id: "one", version: 1, at: 0, kind: "activity", items: [sendMessage] }])[0]).toBe(lines(1));
});

test("a turn's end keeps a reply's room: a folded reply to the person keeps it, a folded note does not", () => {
  const reply = { id: "r", kind: "assistant", text: "The build passed.", version: 1 } as AcpmuxRow;
  const next = { id: "n", kind: "user", text: "next", version: 1 } as AcpmuxRow;
  expect(keepsReplyRoom(reply, next)).toBe(true);
  // turns.ts marks a finished turn's earlier replies settled inside its open "Worked for"; a reply
  // to the person there is `foldedReply`, so the end moves nothing (agent-pane-stream-jitter).
  expect(keepsReplyRoom({ ...reply, settled: true, foldedReply: true }, next)).toBe(true);
  expect(keepsReplyRoom({ ...reply, settled: true }, next)).toBe(false);
  expect(keepsReplyRoom({ ...reply, streaming: true }, next)).toBe(false);
});

// A code card's estimate (model.ts codeCardHeight) follows what the card draws.
const codeWidth = 600;
const codeChars = (room: number) => Math.floor(room / currentChatMetrics().codeCharWidth);

test("a code card estimate reads a fence's first word, as the renderer does (cmux#30836)", () => {
  // Markdown.tsx keeps only the info string's first word, so `text title="tree"` draws unlabeled.
  const tree = "root\n├─ a\n└─ b";
  expect(codeCardHeight(tree, 'text title="tree"', codeWidth)).toBe(codeCardHeight(tree, "text", codeWidth));
  expect(codeCardHeight("a\nb\nc", 'text title="tree"', codeWidth)).toBe(codeCardHeight("a\nb\nc", "", codeWidth));
  const python = codeCardHeight("x = 1", "python", codeWidth);
  expect(codeCardHeight("x = 1", "python  {.numberLines}", codeWidth)).toBe(python);
});

test("a code card scrolls against its text's width, not the card's (cmux#30690)", () => {
  // The body's 13px and 1px margins and the plain card's 8px and 12px padding leave width - 34
  // for text: a line 20px short of the card's edge still scrolls.
  const scrollbar = (code: string) =>
    codeCardHeight(code, "python", codeWidth) - codeCardHeight("x", "python", codeWidth);
  expect(scrollbar("x".repeat(codeChars(codeWidth - 20)))).toBe(15);
  expect(scrollbar("x".repeat(codeChars(codeWidth - 34)))).toBe(0);
});

test("an unlabeled card's first line keeps room for its corner actions (cmux#30689)", () => {
  // A first line that fits the text but not the strip's room after it scrolls; as a later line it fits.
  const line = "x".repeat(codeChars(codeWidth - 34 - 10));
  const scrollbar = (code: string, lang: string) =>
    codeCardHeight(code, lang, codeWidth) - codeCardHeight(code.replace(/x+/, "x"), lang, codeWidth);
  expect(scrollbar(`${line}\nshort`, "")).toBe(15);
  expect(scrollbar(`short\n${line}`, "")).toBe(0);
  // A labeled card's actions sit in its header row, so its first line has the full width.
  expect(scrollbar(`${line}\nshort`, "python")).toBe(0);
});
