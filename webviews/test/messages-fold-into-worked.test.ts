// l10n-allow-file: test fixture prompts, messages and commands, not shipped UI.
// Other agents' messages fold into the finished turn's "Worked for" as regular entries, the
// aggressive fold mode: the messages that woke the chat (acpmux's inbox notice, "Received 2
// messages") and the ones sent and received beside its calls. Opened, they draw where they came,
// in time order among the calls.
//
// Leo, 2026-11-07, on a "Received 2 messages" row on its own right above a closed "Worked for
// 1m 17s": "Do we want to, like, fold the receiving and sending messages into the worked for as
// well? Like the nearest one? ... Maybe it's fine to count as a regular tool call. ... we can
// always just click on the expansions to see them again, right? To see them, as well as, like, you
// know, see them in the places that they would be expected to be."
//
// Before: the notice that started the turn drew above its closed "Worked for" as "Received 2
// messages", and the fold's count left the messages out. After: the closed turn draws "Worked for"
// and the reply; opened, the messages are its first entries, then the calls, each where it came.
// The turn's prompt stays in sight while the turn runs, and in a turn that did nothing to fold.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { LANE_NOTICE_BATCH } from "../src/agent-session/acpmux/model";
import { hiddenRowFolds, turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";
import { projectInboxRows } from "../src/agent-session/acpmux/conversation/laneNoticeBatches";
import { findMatches, isFindRow } from "../src/agent-session/acpmux/conversation/chatFind";
import { incomingPrompt } from "../src/agent-session/acpmux/conversation/incomingMessage";
import { inboxText } from "../src/agent-session/acpmux/conversation/inboxNotice";
import { searchablePendingRows } from "../src/agent-session/acpmux/conversation/pendingMessages";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

let n = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: fields.id ?? `${kind}-${(n += 1)}`,
  version: 1,
  at: (n += 1) * 1000,
  kind,
  ...fields,
});
const tool = (id: string, title: string, kind: string, fields: Record<string, unknown> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: title,
  tool: { id, title, kind, status: "completed", ...fields },
});
const run = (id: string, command: string) => tool(id, command, "execute", { command, output: "ok\n" });
const send = (id: string, to: string, message: string) =>
  tool(id, "SendMessage", "other", { inputSummary: JSON.stringify({ to, message }) });
const activity = (id: string, items: AcpmuxActivity[]) => row("activity", { id, items, toolCount: items.length });

/// acpmux's inbox notice (hub/inbox.rs `render`), the one prompt that wakes an idle chat for the
/// messages that came: one thread per sender.
function inbox(id: string, senders: string[]): AcpmuxRow {
  const threads = senders.map((from, index) => ({
    threadId: `from:${from}`,
    label: "",
    new: 1,
    from: [from],
    promptIds: [`p-${id}-${index}`],
    blocker: false,
    preview: `Status from ${from}`,
    messages: [{ from, promptId: `p-${id}-${index}`, text: `Status from ${from}: the nightly is green.` }],
  }));
  const text = [
    `[inbox] New messages from other agents in ${threads.length} threads.`,
    ...threads.map((t) => `- 1 new from ${t.from[0]}: ${t.preview} (thread ${t.threadId})`),
  ].join("\n");
  const incoming = incomingPrompt(text, {
    client: "acpmux",
    _meta: { provenance: { kind: "inbox_notice", noticeId: `notice-${id}`, threads } },
  });
  if (incoming?.kind !== "inbox") throw new Error("the fixture is not an inbox notice");
  return row("user", { id, text: inboxText(incoming.notice), incoming, untyped: true });
}
/// Another agent's message that came in while the turn ran (a steer into it).
const received = (id: string, name: string, text: string) =>
  row("user", {
    id,
    text,
    continues: true,
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
  });
const summary = (id: string, toolCount: number) =>
  row("turnSummary", { id, status: "completed", toolCount, durationMs: 77_000 } as Partial<AcpmuxRow>);

/// The person's turn before, then the turn of Leo's screenshot: a notice of two messages wakes the
/// chat; the agent runs a command, sends a message, gets one back, runs another and answers.
const chat = (): AcpmuxRow[] => [
  row("user", { id: "prompt", text: "Watch the nightly" }),
  activity("run-0", [run("call-0", "gh run list")]),
  row("assistant", { id: "watching", text: "Watching it." }),
  summary("summary-0", 1),
  inbox("notice", ["build-box/nightly-watch", "lane-box/ux-owner"]),
  activity("run-1", [run("call-1", "gh run view 42")]),
  activity("run-2", [send("call-2", "lane-box/ux-owner", "Nightly is green, go ahead.")]),
  received("reply-in", "lane-box/ux-owner", "Thanks, landing now."),
  activity("run-3", [run("call-3", "gh pr view 7")]),
  row("assistant", { id: "answer", text: "The nightly is green and the owner is landing." }),
  summary("summary-1", 3),
];

/// The drawn rows, as the transcript draws them (one "Received N messages" row for messages next
/// to each other).
const drawn = (rows: AcpmuxRow[], family: string, expanded = new Set<string>(), working = false) =>
  projectInboxRows(turnView(rows, expanded, { agentFamily: family, working })).filter((r) => r.kind !== "date");

/// What a drawn row stands for: its own id, the calls it lists and the rows it holds.
const holds = (r: AcpmuxRow): string[] => [
  r.id,
  ...(r.items ?? []).flatMap((item) => (item.tool ? [item.tool.id] : [])),
  ...(r.laneNoticeBatch?.rows ?? []).flatMap((member) => [member.id, ...(member.joined ?? [])]),
  ...(r.messageRun?.rows ?? []),
  ...(r.joined ?? []),
];
const isMessageRow = (r: AcpmuxRow) => r.kind === LANE_NOTICE_BATCH || (r.kind === "user" && r.incoming !== undefined);
/// The second turn's rows: from its "Worked for" (or, before, the row above it) to its footer.
const secondTurn = (rows: readonly AcpmuxRow[]) => rows.slice(rows.findIndex((r) => r.id === "summary-0") + 1);

for (const family of ["codex", "claude"]) {
  test(`a finished turn's messages draw no row of their own beside its closed Worked for, which counts them (${family})`, () => {
    const rows = secondTurn(drawn(chat(), family));
    expect(rows.filter(isMessageRow)).toEqual([]);
    expect(rows.map((r) => r.kind)).toEqual([WORKED, "assistant", "turnSummary"]);
    // The two messages of the notice and the one received count as calls beside the turn's three.
    expect(rows[0]!.toolCount).toBe(6);
  });

  test(`opened, its Worked for draws the messages where they came, among the calls (${family})`, () => {
    const rows = secondTurn(drawn(chat(), family, new Set([`${WORKED}-notice`])));
    expect(rows[0]!.kind).toBe(WORKED);
    const order = rows.flatMap(holds);
    const at = (id: string) => order.indexOf(id);
    const when = ["notice", "run-1", "run-2", "reply-in", "run-3", "answer"].map(at);
    expect(when.every((index) => index > 0)).toBe(true);
    expect(when).toEqual([...when].sort((a, b) => a - b));
  });

  test(`Find opens the Worked for to a message folded in it (${family})`, () => {
    // As ChatFindScope does: Find searches the chat's rows; a match the transcript does not draw
    // opens the folds that hide it.
    const source = chat();
    const shown = drawn(source, family);
    for (const query of ["ux-owner: the nightly is green", "landing now"]) {
      const [match] = findMatches(source, query);
      expect(match).toBeDefined();
      expect(shown.some((r) => isFindRow(r, match!.rowId))).toBe(false);
      const folds = hiddenRowFolds(source, shown, match!.rowIndex);
      expect(folds).toContain(`${WORKED}-notice`);
      const opened = drawn(source, family, new Set(folds));
      expect(opened.some((r) => isFindRow(r, match!.rowId))).toBe(true);
    }
  });

  test(`Find over the rows it searches opens the Worked for to a message folded in it (${family})`, () => {
    // As App.tsx does: Find searches `searchablePendingRows`, which draws the inbox notice as its
    // deliveries, so the turn's fold is the notice's, not a delivery's (cmux#37903 review F1).
    const source = chat();
    const rows = searchablePendingRows(source, []);
    const shown = drawn(source, family);
    for (const query of ["ux-owner: the nightly is green", "nightly-watch: the nightly is green", "landing now"]) {
      const [match] = findMatches(rows, query);
      expect(match).toBeDefined();
      expect(shown.some((r) => isFindRow(r, match!.rowId))).toBe(false);
      const folds = hiddenRowFolds(rows, shown, match!.rowIndex);
      expect(folds).toContain(`${WORKED}-notice`);
      const opened = drawn(source, family, new Set(folds));
      expect(opened.some((r) => isFindRow(r, match!.rowId))).toBe(true);
    }
  });

  test(`a turn its messages started keeps its minimap tick, its fold open or closed (${family})`, () => {
    // The rail reads the drawn rows; the closed fold draws no prompt, so its "Worked for" stands for
    // it (cmux#37903 review F2).
    for (const expanded of [new Set<string>(), new Set([`${WORKED}-notice`])]) {
      const rows = drawn(chat(), family, expanded);
      const map = minimapTurns(rows, "chat", undefined, undefined, undefined, 2);
      expect(map.turns.map((turn) => turn.id)).toEqual(["prompt", "notice"]);
      expect(map.turns[1]!.from).toBe("build-box/nightly-watch, lane-box/ux-owner");
      expect(rows[map.turns[1]!.index]!.kind).toBe(WORKED);
      expect(map.pendingCount).toBe(0);
    }
    // A turn one agent's message opened, as the prompt itself.
    const message = (): AcpmuxRow[] => [
      ...chat().slice(0, 4),
      row("user", {
        id: "message",
        text: "Is the nightly green?",
        incoming: { kind: "message", message: { name: "lane-box/ux-owner", text: "Is the nightly green?", raw: "" } },
      }),
      activity("run-m", [run("call-m", "gh run view 42")]),
      row("assistant", { id: "answer-m", text: "Yes." }),
      summary("summary-m", 1),
    ];
    for (const expanded of [new Set<string>(), new Set([`${WORKED}-message`])]) {
      const rows = drawn(message(), family, expanded);
      expect(rows.some((r) => r.id === "message")).toBe(expanded.size > 0);
      const map = minimapTurns(rows, "chat", undefined, undefined, undefined, 2);
      expect(map.turns.map((turn) => [turn.id, turn.from])).toEqual([
        ["prompt", undefined],
        ["message", "lane-box/ux-owner"],
      ]);
      expect(map.pendingCount).toBe(0);
    }
  });

  test(`the messages that start a turn stay in sight as its prompt while it runs and when it did no work (${family})`, () => {
    const running = chat().slice(0, -2);
    expect(secondTurn(drawn(running, family, new Set(), true)).flatMap(holds)).toContain("notice");
    const replyOnly = [...chat().slice(0, 5), row("assistant", { id: "ack", text: "Noted." }), summary("summary-1", 0)];
    const rows = secondTurn(drawn(replyOnly, family));
    expect(rows.flatMap(holds)).toContain("notice");
    expect(rows.some((r) => r.kind === WORKED)).toBe(false);
  });

  test(`the person's own prompt stays above its closed Worked for (${family})`, () => {
    const rows = drawn(chat(), family);
    expect(rows[0]!.id).toBe("prompt");
    expect(rows[1]!.kind).toBe(WORKED);
  });
}
