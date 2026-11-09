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
  INLINE_ATTACHMENT_MARGIN,
  INLINE_FILE_CHIP,
  keepsReplyRoom,
  layoutConversation,
  placeRows,
  statusEdge,
  type AcpmuxRow,
  type AcpmuxActivity,
} from "./model";
import { turnView } from "./conversation/turns";
import { COLLAPSED_PROMPT_LINES, PROMPT_MORE_HEIGHT } from "./conversation/promptCollapse";
import { currentChatMetrics } from "./chatDisplay";
import { gridLength, TRANSCRIPT_FOOTER_CONTROL } from "./transcriptGrid";
import { BUBBLE } from "./transcriptSpacing";
import { setComposerSettings } from "./composerSettings";

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

// An attachment-only prompt has no bubble; its action row is laid in the turn gap as a bubble's is
// (conversation.css, model.ts userMetaHeight), so its height is its 128px thumbnail row.
test("an attachment-only prompt reserves its attachment strip", () => {
  const row = { id: "image", version: 1, at: 0, kind: "user", images: [{ id: "i", mimeType: "image/png" }] };
  const [height] = heightsOf([row]);
  expect(height).toBeGreaterThanOrEqual(128);
});

test("an inline attachment-only prompt reserves its attachment strip", () => {
  const row = {
    id: "inline-image",
    version: 1,
    at: 0,
    kind: "user",
    inlineParts: [{ kind: "image", id: "i", mimeType: "image/png" }],
  };
  const [height] = heightsOf([row]);
  expect(height).toBeGreaterThanOrEqual(128);
});

// Blank text after its image still reads as nothing (bubbleParts.ts attachmentOnly): UserBubble.tsx
// draws the strip and no bubble, so the estimate is the strip's, not an inline bubble's, in each view.
test("an attachment-only prompt with blank recorded text reserves only its attachment strip", () => {
  const image = { kind: "image", id: "i", mimeType: "image/png" };
  const bare = { id: "bare", version: 1, at: 0, kind: "user", inlineParts: [image] };
  const blank = {
    id: "blank",
    version: 1,
    at: 0,
    kind: "user",
    text: " ",
    inlineParts: [image, { kind: "text", text: " " }],
  };
  for (const attachmentView of ["inline", "strip"] as const) {
    setComposerSettings({ attachmentView });
    expect(heightsOf([blank])).toEqual(heightsOf([bare]));
  }
  setComposerSettings({ attachmentView: "inline" });
});

// Two wide screenshots draw 320px each and wrap to two rows in a 720px pane's 504px column.
test("two wide images in an attachment-only prompt reserve two thumbnail rows", () => {
  const images = [
    { id: "a", mimeType: "image/png" },
    { id: "b", mimeType: "image/png" },
  ];
  const [one] = heightsOf([{ id: "one", version: 1, at: 0, kind: "user", images: images.slice(0, 1) }]);
  const [two] = heightsOf([{ id: "two", version: 1, at: 0, kind: "user", images }]);
  expect(two! - one!).toBe(128);
});

// A video sent with its frames draws a 120px tile in the thumbnail row, not a 36px file chip.
test("a video-only prompt reserves its tile's thumbnail row", () => {
  const poster = "data:image/jpeg;base64,AA==";
  const video = { width: 1920, height: 1080, durationMs: 4_000, poster, frames: ["f"] };
  const chip = { id: "v", kind: "link", name: "clip.mp4", path: "/c.mp4", mimeType: "video/mp4", size: 1, video };
  const [height] = heightsOf([{ id: "video", version: 1, at: 0, kind: "user", retryAttachments: [chip] }]);
  expect(height).toBeGreaterThanOrEqual(128);
});

// Its clock sits beside the attachment band (UserBubble.tsx), so the row keeps its height when it lands.
test("an attachment-only send keeps its height when it lands", () => {
  const row = {
    id: "sending-image",
    version: 1,
    at: 0,
    kind: "user",
    inlineParts: [{ kind: "image", id: "i", mimeType: "image/png" }],
  };
  const [sent] = heightsOf([row]);
  const [sending] = heightsOf([{ ...row, delivery: { state: "sending", promptId: "p", sessionId: "s", sentAt: 0 } }]);
  expect(sending!).toBe(sent!);
});

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
      sessionStatus: true,
    });
    const settled = turnView(
      [...source, { id: "s", version: 1, at: 3_000, kind: "turnSummary", status: "completed", text }] as never,
      new Set(),
      { now: 4_000, sessionStatus: true },
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
    sessionStatus: true,
  });
  expect(live.at(-1)).toMatchObject({ kind: "activityLine", below: true });
  expect(settled.at(-1)).toMatchObject({ kind: "turnSummary" });
  expect(layoutConversation(live, 720).heights.at(-1)).toBe(TRANSCRIPT_FOOTER_CONTROL);
  expect(layoutConversation(settled, 720).heights.at(-1)).toBe(TRANSCRIPT_FOOTER_CONTROL);
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
// lines over the 24px Show more line, inside the bubble's block padding (what a 44px one-line
// bubble leaves its line, transcriptSpacing.ts BUBBLE), with its 28px hover row under it and the
// 8px message gap. Estimated any taller, the row shrinks once drawn and the rows below jump up.
// Before: a prompt was estimated at its whole text, 2,000 lines tall.
test("a 2,000-line prompt is estimated at its collapsed height, at most twenty lines", () => {
  const { lineHeight } = currentChatMetrics();
  const padding = BUBBLE.oneLine - lineHeight;
  const text = Array.from({ length: 2000 }, (_, index) => `line ${index + 1}`).join("\n");
  const [long] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text }]);
  expect(long).toBeCloseTo(padding + COLLAPSED_PROMPT_LINES * lineHeight + PROMPT_MORE_HEIGHT, 5);
  expect(long!).toBeLessThan(padding + 20.5 * lineHeight + 24 + 28 + 8);
});

test("a prompt of twenty lines or fewer is estimated whole, with no Show more line", () => {
  const { lineHeight } = currentChatMetrics();
  const text = Array.from({ length: 3 }, (_, index) => `line ${index + 1}`).join("\n\n");
  const [short] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text }]);
  expect(short!).toBeLessThan(BUBBLE.oneLine - lineHeight + COLLAPSED_PROMPT_LINES * lineHeight + 28 + 8);
});

// A paste is part of the message's one text body (ask-14d16a6247): a long one is estimated as the
// prompt's folded lines and its Show more, as typed text is.
test("a prompt with a 2,300-line paste drawn as text is estimated at the prompt's fold", () => {
  const { lineHeight } = currentChatMetrics();
  const typed = "Why does this fail?";
  const paste = Array.from({ length: 2300 }, (_, index) => `frame ${index}`).join("\n");
  const text = `${typed}\n${paste}`;
  const pasted = [{ start: typed.length + 1, end: text.length }];
  const [height] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text, pasted }]);
  expect(height).toBeCloseTo(BUBBLE.oneLine - lineHeight + COLLAPSED_PROMPT_LINES * lineHeight + PROMPT_MORE_HEIGHT, 5);
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
  // Two sends, as two calls or as one shell batch: one closed "Sent 2 messages" line
  // (toolGroups.ts `sendGroup`; Leo, 2026-11-04: "why arent these collapsed/collapsible").
  expect(heightsOf(run([send("a", "lane-a"), send("b", "lane-b")]))[0]).toBe(lines(1));
  expect(heightsOf(run([shell("a", "acpmux send --no-wait lane-a 'a'; acpmux send --no-wait lane-b 'b'")]))[0]).toBe(
    lines(1),
  );
  // Not folded, two calls that each sent one are that one line too.
  expect(
    heightsOf([
      { id: "two", version: 1, at: 0, kind: "activity", items: [send("a", "lane-a"), send("b", "lane-b")] },
    ])[0],
  ).toBe(lines(1));
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

test("a note folded between tool rows is estimated as the lines it wraps to at the column's width", () => {
  // turns.ts mergeShortNotes folds the note into the run; conversation.css `.cv-tool-note` draws it on
  // 20px lines with the 12px note gap above and below (cmux#31148).
  const shell = (id: string) => ({
    kind: "tool",
    text: "Bash",
    tool: { id, title: "Bash", kind: "execute", status: "completed", command: "git status" },
  });
  const run = (note: string) => [
    { id: "run", version: 1, at: 0, kind: "activity", items: [shell("a"), { kind: "note", text: note }, shell("b")] },
  ];
  const at = (note: string, width: number) => layoutConversation(run(note) as never, width).heights[0]!;
  // A short note is one 20px line between its gaps; the run's rows and the gaps are the rest.
  const oneLine = at("Checking the tests.", 720);
  const long = "Now the tests pass, so the next step is the migration and its rollback path. ".repeat(4);
  // A long note wraps: its extra lines are 20px each, more of them in a narrow pane.
  const wide = at(long, 720) - oneLine;
  const narrow = at(long, 360) - oneLine;
  expect(wide).toBeGreaterThanOrEqual(20);
  expect(wide % 20).toBe(0);
  expect(narrow % 20).toBe(0);
  expect(narrow).toBeGreaterThan(wide);
  // The note wraps with `white-space: normal`: a newline in a short note draws as a space, one line.
  expect(at("Checking\nthe tests.", 720)).toBe(oneLine);
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

// Successful discovery must not add phantom summary lines around coordination entries: the
// virtualizer estimates exactly the same visible run as ToolRows before its first DOM measure.
test("hidden discovery contributes no compact height around coordination messages", () => {
  const send: AcpmuxActivity = {
    kind: "tool",
    text: "SendMessage",
    tool: {
      id: "height-send",
      title: "SendMessage",
      kind: "other",
      status: "completed",
      inputSummary: JSON.stringify({ to: "helper", message: "Check the result" }),
    },
  };
  const discovery: AcpmuxActivity = {
    kind: "tool",
    text: "ToolSearch",
    tool: {
      id: "height-discovery",
      title: "ToolSearch",
      kind: "other",
      status: "completed",
      provenance: { claudeTool: "ToolSearch" },
      output: "Loaded 2 tools",
    },
  };
  const activity = (items: AcpmuxActivity[], foldRun?: boolean): AcpmuxRow => ({
    id: "visible-run",
    version: 1,
    at: 0,
    kind: "activity",
    items,
    foldRun,
  });
  for (const folded of [undefined, true]) {
    const plain = heightsOf([activity([send], folded)])[0]!;
    expect(heightsOf([activity([discovery, send, discovery], folded)])[0]).toBe(plain);
    const failed = { ...discovery, tool: { ...discovery.tool!, status: "failed", output: "Discovery unavailable" } };
    expect(heightsOf([activity([failed, send], folded)])[0]).toBeGreaterThan(plain);
  }
  expect(heightsOf([activity([discovery])])[0]).toBeGreaterThan(0);
  expect(heightsOf([activity([discovery], true)])[0]).toBeGreaterThan(0);
  const answer = reply("discovery-answer", "Done.");
  const summary = footer("discovery-footer");
  const without = layoutConversation([answer, summary], 720);
  const withHidden = layoutConversation([answer, activity([discovery]), summary], 720);
  expect(withHidden.heights[0]).toBe(without.heights[0]);
  expect(withHidden.heights[1]).toBeGreaterThan(0);
  expect(withHidden.tops[2]).toBeGreaterThan(without.tops[1]);
  expect(withHidden.totalHeight).toBeGreaterThan(without.totalHeight);
  // Preserve the pre-existing empty activity placeholder, rather than erasing unrelated rows.
  expect(heightsOf([activity([])])[0]).toBeGreaterThan(0);
});

const permissionAsk = (overrides: Partial<NonNullable<AcpmuxRow["permission"]>> = {}): AcpmuxRow => ({
  id: "permission",
  version: 1,
  at: 0,
  kind: "permission",
  permission: {
    permissionId: "ask",
    pending: true,
    title: "Read project files",
    kind: "read",
    options: [{ id: "allow_once", kind: "allow_once", name: "Allow once", allow: true }],
    ...overrides,
  },
});
const questionAsk = (count: number, description?: string): AcpmuxRow =>
  permissionAsk({
    question: {
      id: "question",
      source: { harness: "claude", session: "fixture" },
      state: { kind: "pending" },
      items: [
        {
          id: "item",
          prompt: "Choose a format",
          multiSelect: false,
          allowsOther: false,
          options: Array.from({ length: count }, (_, index) => ({
            id: String(index),
            label: `Format ${index}`,
            detail: description,
          })),
        },
      ],
    },
  });

test("permission estimates use the grid frame and reserve a command preview only when drawn", () => {
  const plain = heightsOf([permissionAsk()])[0]!;
  // 16px around the 18px title, then 12px above and 16px below a 28px button row.
  expect(plain).toBeCloseTo(16 + 18 + 16 + 12 + 28 + 16);
  const command = heightsOf([permissionAsk({ command: "pwd" })])[0]!;
  // The details band's 12px, then the preview's 8px insets around one 12px/1.5 line.
  expect(command - plain).toBeCloseTo(12 + 8 + 12 * 1.5 + 8);
  const scope = heightsOf([permissionAsk({ scope: { kind: "directory", value: "/project" } })])[0]!;
  expect(scope - plain).toBeCloseTo(12 + 11 * 1.3);
  const both = heightsOf([permissionAsk({ command: "pwd", scope: { kind: "directory", value: "/project" } })])[0]!;
  expect(both - plain).toBeCloseTo(12 + 8 + 12 * 1.5 + 8 + 8 + 11 * 1.3);
});

test("the first layout reserves every question option before placing the reply below", () => {
  const two = layoutConversation([questionAsk(2), reply("after", "Next")] as AcpmuxRow[], 720);
  const five = layoutConversation([questionAsk(5), reply("after", "Next")] as AcpmuxRow[], 720);
  expect(two.heights[0]).toBeCloseTo(32 + 1 + 24 + 18 + 0.5 + 8 + 2 * 36 + 44);
  expect(five.heights[0]! - two.heights[0]!).toBe(3 * 36);
  expect(five.tops[1]! - two.tops[1]!).toBe(3 * 36);
});

test("question estimates follow description wrapping at the actual column width", () => {
  const row = questionAsk(3, "The format retains the original metadata and supports every project export.");
  const wide = layoutConversation([row], 720);
  const narrow = layoutConversation([row], 220);
  expect(narrow.heights[0]!).toBeGreaterThan(wide.heights[0]!);
  expect(heightsOf([questionAsk(3)])[0]!).toBeLessThan(wide.heights[0]!);
});

test("narrow permission action rows and two-line commands reserve their extra height", () => {
  const row = permissionAsk({
    command: "printf '%s' ".repeat(12),
    options: [
      { id: "allow_once", kind: "allow_once", name: "Allow once", allow: true },
      { id: "allow_always", kind: "allow_always", name: "Always allow", allow: true },
      { id: "deny", kind: "reject_once", name: "Deny", allow: false },
    ],
  });
  expect(layoutConversation([row], 180).heights[0]!).toBeGreaterThan(layoutConversation([row], 720).heights[0]!);
});

test("plan and blocked-read asks reserve the parts their cards draw", () => {
  const plain = heightsOf([permissionAsk()])[0]!;
  const plan = heightsOf([permissionAsk({ plan: "## Plan\n\n" + "1. Step through the change.\n".repeat(4) })])[0]!;
  expect(plan).toBeGreaterThan(plain + 8 + 16);
  const long = heightsOf([permissionAsk({ plan: "1. Step.\n".repeat(200) })])[0]!;
  // The plan scrolls inside the card past 320px.
  expect(long - plain).toBeLessThanOrEqual(8 + 320);
  const external = heightsOf([
    permissionAsk({
      scope: { kind: "directory", value: "/Users/you/Documents" },
      externalAccess: {
        kind: "files_and_folders",
        target: "/Users/you/Documents/report.txt",
        operation: "read_text_file",
        platform: "macos",
      },
    }),
  ])[0]!;
  // Its macOS detail line shows, and no scope line under the buttons.
  expect(external).toBeGreaterThan(plain + 8);
});

// A prompt drawn in its parts' order (conversation/InlinePromptContent.tsx) is estimated from what
// its bubble draws, not its recorded text: a text file is its chip, never the body behind it, and a
// placed paste joins its typed words as the draft had them, not on lines of its own.
test("a sent text file is estimated as its chip, not its long body", () => {
  const { lineHeight } = currentChatMetrics();
  const padding = BUBBLE.oneLine - lineHeight;
  const typed = "Read this file";
  const fileRow = (body: string) => ({
    id: "u",
    version: 1,
    at: 0,
    kind: "user",
    text: `${typed}\n${body}`,
    inlineParts: [
      { kind: "text", text: typed },
      { kind: "file", name: "notes.txt", mimeType: "text/plain", text: body, placed: true },
    ],
  });
  const long = Array.from({ length: 400 }, (_, index) => `note ${index}`).join("\n");
  const [height] = heightsOf([fileRow(long)]);
  // Its chip sits on its typed line (an inline block, `.cv-user__inline-file`): the line is the chip's
  // 32px and its 2px above and below.
  expect(height).toBeCloseTo(padding + INLINE_FILE_CHIP.height + 2 * INLINE_ATTACHMENT_MARGIN.y, 5);
  expect(heightsOf([fileRow("one line")])[0]).toBe(height!);
});

test("a placed paste is estimated as the one body its bubble draws", () => {
  const { lineHeight } = currentChatMetrics();
  const padding = BUBBLE.oneLine - lineHeight;
  // Ten short pastes between typed words: the draft reads as one run of words; the record keeps
  // acpmux's join, a line each.
  const parts = Array.from({ length: 10 }, (_, index) => [
    { kind: "text", text: ` w${index} ` },
    { kind: "pasted", name: `paste ${index}`, text: `p${index}`, placed: true },
  ]).flat();
  const text = parts.map((part) => part.text).join("\n");
  const [height] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text, inlineParts: parts }]);
  const drawn = parts.map((part) => part.text).join("");
  expect(heightsOf([{ id: "drawn", version: 1, at: 0, kind: "user", text: drawn }])[0]).toBe(height!);
  expect(height!).toBeLessThan(padding + 4 * lineHeight);
});

// An attachment in a placed prompt's text is an inline block on the text's line, as the bubble's CSS
// flows it (`.cv-user__inline-content`, `pre-wrap`): a line is as tall as its tallest thumbnail, an
// image is its own sent size (UserBubble.tsx `sentImageSize`, up to 320px wide), and an image's
// retained original, which the bubble does not draw, takes no room. At ac67fede each image was a
// 128px-wide row of its own under the text, and a companion file a chip row too.
test("a placed image is estimated at its own size, on its text's line", () => {
  const { lineHeight } = currentChatMetrics();
  const padding = BUBBLE.oneLine - lineHeight;
  const { y } = INLINE_ATTACHMENT_MARGIN;
  const row = (parts: unknown[]) => ({ id: "u", version: 1, at: 0, kind: "user", text: "look", inlineParts: parts });
  // A 1600x400 screenshot draws 320x80, whole.
  const wide = { kind: "image", id: "wide", mimeType: "image/png", width: 1600, height: 400, placed: true };
  expect(heightsOf([row([{ kind: "text", text: "look " }, wide])])[0]).toBeCloseTo(padding + 80 + 2 * y, 5);
  // A square one with no known size draws 120x120; the words after it share its line.
  const square = { kind: "image", id: "sq", mimeType: "image/png", blockIndex: 0 };
  const companion = { kind: "file", name: "shot.heic", uri: "file:///tmp/shot.heic", companionOf: 0 };
  const [withOriginal] = heightsOf([row([square, companion, { kind: "text", text: " then words" }])]);
  expect(withOriginal).toBeCloseTo(padding + 120 + 2 * y, 5);
  expect(heightsOf([row([square, { kind: "text", text: " then words" }])])[0]).toBe(withOriginal!);
});

test("placed attachments wrap to a new line only when the line is full", () => {
  const { lineHeight } = currentChatMetrics();
  const padding = BUBBLE.oneLine - lineHeight;
  const { y } = INLINE_ATTACHMENT_MARGIN;
  const image = (id: string) => ({ kind: "image", id, mimeType: "image/png", placed: true });
  const row = (count: number) => ({
    id: "u",
    version: 1,
    at: 0,
    kind: "user",
    text: "four",
    inlineParts: [{ kind: "text", text: "four " }, ...Array.from({ length: count }, (_, index) => image(`i${index}`))],
  });
  // Each 120px image is 128px with its margins; at 720px the bubble's text is about 480px wide, so
  // three fit beside the word and a fourth starts the next line.
  const tile = 120 + 2 * y;
  expect(heightsOf([row(3)])[0]).toBeCloseTo(padding + tile, 5);
  expect(heightsOf([row(4)])[0]).toBeCloseTo(padding + 2 * tile, 5);
});

// The strip attachment view (composerSettings.ts `attachmentView`) draws a placed prompt's
// attachments in a row above its bubble and leaves the bubble its text (UserBubble.tsx); a placed
// prompt's unmarked attachment draws in that row in the inline view too. The estimate measures that
// row and a bubble of the text alone, so the row does not shift when it mounts. At 1543d956 every
// such prompt was estimated as if each attachment sat on its text's line.
test("a strip prompt is estimated as its attachment row over a bubble of its text", () => {
  const { y } = INLINE_ATTACHMENT_MARGIN;
  const tile = 120 + 2 * y;
  const image = (id: string, placed = true) => ({
    kind: "image",
    id,
    mimeType: "image/png",
    ...(placed ? { placed: true } : {}),
  });
  const row = (parts: unknown[]) => ({
    id: "u",
    version: 1,
    at: 0,
    kind: "user",
    text: "look\nthen words",
    inlineParts: parts,
  });
  const text = heightsOf([{ id: "t", version: 1, at: 0, kind: "user", text: "look\nthen words" }])[0]!;
  const interleaved = row([{ kind: "text", text: "look" }, image("a"), { kind: "text", text: "then words" }]);
  const inline = heightsOf([interleaved])[0]!;
  setComposerSettings({ attachmentView: "strip" });
  try {
    expect(heightsOf([interleaved])[0]).toBeCloseTo(text + tile, 5);
    expect(heightsOf([interleaved])[0]).not.toBeCloseTo(inline, 5);
    // Two images share the row: it wraps only when full.
    const two = row([{ kind: "text", text: "look" }, image("a"), image("b"), { kind: "text", text: "then words" }]);
    expect(heightsOf([two])[0]).toBeCloseTo(text + tile, 5);
  } finally {
    setComposerSettings({ attachmentView: "inline" });
  }
  // Inline, the placed prompt's unmarked image is the row above; the placed one stays in the text.
  const placedOnly = row([{ kind: "text", text: "look" }, image("a"), { kind: "text", text: "then words" }]);
  const withBand = row([
    { kind: "text", text: "look" },
    image("a"),
    { kind: "text", text: "then words" },
    image("b", false),
  ]);
  expect(heightsOf([withBand])[0]).toBeCloseTo(heightsOf([placedOnly])[0]! + tile, 5);
});

// Leo, 2026-11-08: "the text in this situation isn't from the subagent?". A turn the agent ran on
// its own that draws as its own turn (no line over it) stands the turn gap from the row above, as a
// prompt's turn does, in the first layout as in the drawn one (transcriptGrid.ts MARK_OPENS_TURN);
// the rows inside it and the footer under it keep their own gaps. The subagent's line is estimated
// with only its short note under it, never the agent's replies.
test("a turn the agent ran on its own opens with the turn gap, its rows and footer as any turn's", () => {
  const done = {
    id: "subagentDone:fixer",
    version: 1,
    at: 0,
    kind: "subagentDone",
    subagents: [{ id: "fixer", parent: null, name: "fixer", state: "completed", startedAt: 0 }],
  };
  const own = (n: number) => [
    { ...reply(`own-${n}`, "Hourly pass done. Every unmet goal now has a live owner."), inBackground: `bg-${n}` },
    { ...footer(`backgroundEnd-bg-${n}`), inBackground: undefined },
  ];
  const rows = [reply("a", "Started a subagent."), footer("f"), done, ...own(1), ...own(2)];
  const layout = layoutConversation(rows as never, 720);
  const gapOver = (index: number) => layout.tops[index]! - layout.tops[index - 1]! - layout.heights[index - 1]!;
  // Under the subagent's line, and under the first own turn's footer: the turn gap.
  expect(gapOver(3)).toBe(gridLength("gap-turn"));
  expect(gapOver(5)).toBe(gridLength("gap-turn"));
  // The footer sits under its reply as any reply's does.
  expect(gapOver(4)).toBe(gridLength("gap-footer"));
  // The subagent's line is its one row: nothing of the agent's replies is counted in it.
  expect(layout.heights[2]).toBe(layoutConversation([done] as never, 720).heights[0]);
});
