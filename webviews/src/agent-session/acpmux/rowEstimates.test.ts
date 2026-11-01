// l10n-allow-file: test fixture replies, not shipped UI.
// The virtualizer's first-layout estimates (model.ts layoutConversation) match what the transcript's
// CSS draws (conversation/conversation.css, styles.css), so a row that mounts moves nothing below it
// and scrolling up never jumps:
//   - a reply right over its turn's footer (`.acpmux-row--before-footer`), or over the running turn's
//     line that the footer takes the place of: its text and the 4px meta gap, with no 34px floor;
//   - a task's result (`.cv-received`): its 26px line and the 8px message gap;
//   - another agent's message: its one disclosure line, however long the message;
//   - a turn's footer: its 24px line and the 16px turn gap, including the chat's last one
//     (`.acpmux-row--last-footer`), so the composer uses the same rhythm as the transcript.
//
// Before: a reply over a footer was estimated as any reply (8px below it, at least 34px), and a
// task's result kept the old 16px below it.
import { expect, test } from "bun:test";
import { hasReplyActions, layoutConversation, placeRows, statusEdge, type AcpmuxRow } from "./model";
import { turnView } from "./conversation/turns";
import { COLLAPSED_PROMPT_LINES, PASTE_CHIP_HEIGHT, PROMPT_MORE_HEIGHT } from "./conversation/promptCollapse";
import { currentChatMetrics } from "./chatDisplay";

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

test("a reply over its footer is its text and the 4px meta gap, with no 34px floor", () => {
  const long = "A longer answer that wraps. ".repeat(40);
  const [alone] = heightsOf([reply("a", long)]);
  const [over, summary] = heightsOf([reply("a", long), footer("f"), prompt("p")]);
  // The same text: 8px below it alone, 4px over its footer.
  expect(alone! - over!).toBeCloseTo(4, 5);
  // The footer always keeps its 24px line and the 16px turn gap, including the last one.
  expect(summary).toBe(40);
  expect(heightsOf([reply("a", long), footer("f")])[1]).toBe(40);
  // A one-line reply over its footer is shorter than a row's 34px floor.
  const [short] = heightsOf([reply("b", "Done."), footer("g")]);
  expect(short!).toBeLessThan(34);
  expect(short! - 4).toBeGreaterThan(0);
});

test("a reply over its running turn's line is estimated as over the footer that takes its place", () => {
  const long = "A longer answer that wraps. ".repeat(40);
  // The running turn's line as its last row (conversation/turns.ts `below`): the footer's height.
  const line = { id: "live", version: 1, at: 0, kind: "thinking", below: true };
  const [running, lineHeight] = heightsOf([reply("a", long), line]);
  const [ended, footerHeight] = heightsOf([reply("a", long), footer("f")]);
  // The turn's end swaps the line for the footer and moves nothing above it.
  expect(lineHeight).toBe(footerHeight);
  expect(running).toBe(ended);
});

test("a reply estimated alone, then with its footer after it, is estimated again", () => {
  const rows = [reply("a", "Done.")];
  const first = layoutConversation(rows as never, 720);
  expect(first.heights[0]).toBe(34);
  const next = [...rows, footer("f")];
  const second = layoutConversation(next as never, 720, undefined, undefined, undefined, {
    rows,
    layout: first,
  });
  expect(second.heights[0]).toBeLessThan(34);
  expect(second.tops[1]).toBe(second.heights[0]);
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
    expect(layoutConversation(live, 720).heights.at(-1)).toBe(40);
    expect(layoutConversation(settled, 720).heights.at(-1)).toBe(40);
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
  expect(layoutConversation(live, 720).heights.at(-1)).toBe(40);
  expect(layoutConversation(settled, 720).heights.at(-1)).toBe(40);

  const legacy = turnView(liveSource as never, new Set(), {
    now: 5_000,
    working: true,
    lineBelow: false,
    liveRuns: false,
    sessionStatus: true,
  });
  expect(legacy.at(-1)).toMatchObject({ kind: "activityLine" });
  expect(legacy.at(-1)?.below).toBeUndefined();
  expect(layoutConversation(legacy, 720).heights.at(-1)).toBe(34);
});

test("the chat's last footer is placed again when a prompt follows it", () => {
  const rows = [reply("a", "Done."), footer("f")];
  const first = layoutConversation(rows as never, 720);
  expect(first.heights[1]).toBe(40);
  const second = layoutConversation([...rows, prompt("p")] as never, 720, undefined, undefined, undefined, {
    rows,
    layout: first,
  });
  expect(second.heights[1]).toBe(40);
});

test("a footer over another agent's line or a task's result keeps the turn gap", () => {
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
  for (const line of [result, message, notice]) expect(heightsOf([reply("a", "Done."), footer("f"), line])[1]).toBe(40);
  // The person's prompt after it still starts a turn of its own.
  expect(heightsOf([reply("a", "Done."), footer("f"), prompt("p")])[1]).toBe(40);
});

test("a task's result is its 26px line and the 8px message gap", () => {
  const [height] = heightsOf([
    { id: "r", version: 1, at: 0, kind: "user", text: "Run the tests", received: { offerId: "o", title: "Tests" } },
  ]);
  expect(height).toBe(34);
});

test("a footer shaped by turnView, which carries its answer's text, is its 24px line and gap", () => {
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
  expect(heights[footers[0]!]).toBe(40);
  expect(heights[footers[1]!]).toBe(40);
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
  expect(heights.at(-1)).toBe(42);
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
    else if (final.kind === "activity") expect(withGap - withoutMarker).toBe(12);
    else expect(withGap - withoutMarker).toBe(8);
  }
});

test("a hidden row after the chat's last footer leaves it the last one", () => {
  const hidden = { id: "h", version: 1, at: 0, kind: "user", text: "", incoming: { kind: "hidden" } };
  const heights = heightsOf([reply("a", "Done."), footer("f"), hidden]);
  expect(heights[1]).toBe(40);
  expect(heights[2]).toBe(0);
});

test("another agent's message is its one 26px line in 2px margins and the 8px message gap, however long", () => {
  const row = (id: string, text: string) => ({
    id,
    version: 1,
    at: 0,
    kind: "user",
    text,
    incoming: { kind: "message", message: { name: "cmux16/glass-lens", text, raw: text } },
  });
  const [short, long] = heightsOf([row("m1", "Draft is up."), row("m2", "Line of the report.\n".repeat(40))]);
  expect(short).toBe(2 + 26 + 2 + 8);
  expect(long).toBe(short);
});

test("a task notice is a tool row's line, 2px under the row's top, and the 8px message gap", () => {
  const [height] = heightsOf([
    { id: "n", version: 1, at: 0, kind: "user", text: "Task done", incoming: { kind: "notice", text: "Task done" } },
  ]);
  expect(height).toBe(2 + 26 + 8);
});

// A waiting steer's Send now leads the existing action row, so it adds no height to a text prompt.
test("a steer the agent has not read is as tall as a read one: its Send now leads the action row", () => {
  const steer = (state: string) => ({ id: "s", version: 1, at: 0, kind: "user", text: "Also this", steer: state });
  const [landed] = heightsOf([steer("landed")]);
  const [waiting] = heightsOf([steer("waiting")]);
  expect(waiting).toBe(landed!);
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
  expect(long).toBeCloseTo(16 + COLLAPSED_PROMPT_LINES * lineHeight + PROMPT_MORE_HEIGHT + 4 + 24 + 8, 5);
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
  expect(height).toBeCloseTo(16 + lineHeight + PASTE_CHIP_HEIGHT + 28 + 8, 5);
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
    // No reply draws its own action row (a turn's copy lives in its footer), but it keeps that row's
    // room (model.ts keepsReplyRoom; Leo, 2026-11-01: "i like this spacing kinda i prefer it to what
    // we have now"): the same 36px over the run as over a prompt. The run keeps the plain 12px under it.
    expect(step).toBe(2 + 22 + 12);
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
