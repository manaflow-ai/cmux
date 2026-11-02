// A finished turn folds its work under "Worked for", as the Codex and Claude desktop apps do, and
// its last reply stays open below the fold. A reply is never folded, also when the turn ran a tool
// after it (Leo, 2026-10-21, nightly 331e2e9: the final reply sat inside "Worked for 1m 7s";
// "Those replies should never be collapsed"); the tool after it folds with the rest. Only short
// interim notes the turn worked on after are status, and fold: a turn whose only text was such
// notes (or that stopped mid-tool) has no answer.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import { isVisiblyEmptyMessage } from "../src/agent-session/acpmux/conversation/visibleMessage";
import { layoutConversation } from "../src/agent-session/acpmux/model";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const tool = (id: string, kind = "read") =>
  row(id, "activity", { items: [{ kind: "tool", text: "", tool: { id, title: id, kind, status: "completed" } }] });
const text = (id: string) => row(id, "assistant", { text: id });
/// A reply longer than a short interim note (turns.ts SHORT_NOTE_CHARS).
const reply = (id: string) =>
  row(id, "assistant", {
    text: "Your old messages aren't gone; the app just doesn't load them. ".repeat(4) + "\n\n- one\n- two",
  });
const summary = (status = "completed") => row("end", "turnSummary", { status, durationMs: 9_000 });
// The turn's rows as drawn, without the day separators above them.
const drawn = (rows: AcpmuxRow[], expanded: ReadonlySet<string> = new Set()) =>
  turnView(rows, expanded)
    .filter((shaped) => shaped.kind !== "date")
    .map((shaped) => `${shaped.kind}:${shaped.id}`);

test("the answer stays open below the fold of the work before it", () => {
  const rows = [row("u", "user"), text("interim"), tool("read"), text("answer"), summary()];
  expect(drawn(rows)).toEqual(["user:u", "worked:worked-u", "assistant:answer", "turnSummary:end"]);
});

test("a turn that ended on a tool folds its interim text with the rest", () => {
  const rows = [row("u", "user"), text("interim-1"), tool("read"), text("interim-2"), tool("grep"), summary()];
  expect(drawn(rows)).toEqual(["user:u", "worked:worked-u", "turnSummary:end"]);
});

test("empty and zero-width assistant messages between tool groups add no row or footer space", () => {
  const first = tool("first");
  const second = tool("second", "execute");
  const base = [row("u", "user", { text: "Run both checks." }), first, second, summary()];
  const withEmpty = [
    row("u", "user", { text: "Run both checks." }),
    first,
    row("empty", "assistant", { text: "" }),
    row("zero-width", "assistant", { text: "\u200B\u200C\u200D\uFEFF\u2060" }),
    second,
    summary(),
  ];
  const expanded = new Set(["worked-u"]);
  const normal = turnView(base, expanded);
  const shaped = turnView(withEmpty, expanded);
  expect(shaped.filter((entry) => entry.kind === "assistant")).toHaveLength(0);
  expect(shaped.filter((entry) => entry.kind === "turnSummary")).toHaveLength(1);
  expect(layoutConversation(shaped, 760).totalHeight).toBe(layoutConversation(normal, 760).totalHeight);
});

test("an empty completed notification turn has no footer, while a failed one keeps recovery UI", () => {
  const hidden = row("hidden", "user", { incoming: { kind: "hidden" } as never });
  const empty = [hidden, row("empty", "assistant", { text: "\u200B" }), summary()];
  expect(turnView(empty, new Set())).toEqual([]);
  expect(turnView([row("empty-prompt", "user", { text: "" }), summary()], new Set())).toEqual([]);
  const failed = [hidden, row("failed", "assistant", { text: "" }), summary("failed")];
  expect(turnView(failed, new Set()).map((entry) => entry.kind)).toEqual(["turnSummary"]);
});

test("an invisible prompt keeps its logical boundary without adding layout space", () => {
  const prompt = row("invisible-prompt", "user", { text: "\u200B" });
  const shaped = turnView([prompt, tool("read"), text("answer"), summary()], new Set());
  expect(shaped.map((entry) => entry.id)).toContain(prompt.id);
  const withoutPrompt = shaped.filter((entry) => entry.id !== prompt.id);
  expect(layoutConversation(shaped, 760).totalHeight).toBe(layoutConversation(withoutPrompt, 760).totalHeight);
});

test("an attachment-only prompt is still visible when its text is empty", () => {
  const attachment = row("attachment", "user", {
    text: "",
    inlineParts: [{ kind: "file", name: "notes.txt", blockIndex: 1 }] as never,
  });
  expect(turnView([attachment, summary()], new Set()).map((entry) => entry.id)).toContain("attachment");
  const received = row("received", "user", { text: "", received: {} as never });
  expect(turnView([received, summary()], new Set()).map((entry) => entry.id)).toContain("received");
});

test("an invisible failed prompt keeps its delivery recovery row", () => {
  const failed = row("failed-prompt", "user", {
    text: "\u200B",
    failed: true,
    error: "The prompt was not sent.",
    delivery: {
      state: "failed",
      promptId: "prompt-1",
      sessionId: "session-1",
      sentAt: 1,
    },
  });
  expect(isVisiblyEmptyMessage(failed)).toBe(false);
  expect(turnView([failed, summary("failed")], new Set()).map((entry) => entry.id)).toContain("failed-prompt");
});

test("a turn stopped mid-tool folds its work under the stop line", () => {
  const rows = [row("u", "user"), text("interim"), tool("build"), summary("cancelled")];
  expect(drawn(rows)).toEqual(["user:u", "worked:worked-u", "turnSummary:end"]);
});

test("a turn that edited and then ran a tool in one step folds its interim text", () => {
  const step = row("step", "activity", {
    items: [
      { kind: "tool", text: "", tool: { id: "patch", title: "patch", kind: "edit", status: "completed" } },
      { kind: "tool", text: "", tool: { id: "test", title: "test", kind: "execute", status: "completed" } },
    ],
  });
  const rows = [row("u", "user"), text("interim"), step, summary("cancelled")];
  const shaped = drawn(rows);
  expect(shaped.slice(0, 2)).toEqual(["user:u", "worked:worked-u"]);
  expect(shaped).not.toContain("assistant:interim");
});

test("an edit after the answer still joins the turn's edit card, and the answer stays open", () => {
  const rows = [row("u", "user"), tool("read"), text("answer"), tool("patch", "edit"), summary()];
  const shaped = drawn(rows);
  expect(shaped.slice(0, 3)).toEqual(["user:u", "worked:worked-u", "assistant:answer"]);
  expect(shaped.at(-1)).toBe("turnSummary:end");
  expect(shaped.filter((entry) => entry === "activity:patch")).toHaveLength(1);
});

test("an earlier turn without a summary draws as it came, its text in place (no auto fold)", () => {
  const rows = [
    row("u1", "user"),
    text("interim"),
    tool("read"),
    row("u2", "user"),
    text("answer-2"),
    row("end-2", "turnSummary", { status: "completed", durationMs: 1_000 }),
  ];
  const shaped = drawn(rows);
  expect(shaped.slice(0, shaped.indexOf("user:u2"))).toEqual(["user:u1", "assistant:interim", "activity:read"]);
});

test("expanding the fold of a turn that ended on a tool shows the interim text and tools in order", () => {
  const rows = [row("u", "user"), text("interim"), tool("read"), summary()];
  expect(drawn(rows, new Set(["worked-u"]))).toEqual([
    "user:u",
    "worked:worked-u",
    "assistant:interim",
    "activity:read",
    "turnSummary:end",
  ]);
});

test("a reply the turn ran a tool after stays open below the fold, and the tool folds", () => {
  const rows = [
    row("u", "user"),
    tool("defaults read", "execute"),
    reply("answer"),
    tool("send", "execute"),
    summary(),
  ];
  expect(drawn(rows)).toEqual(["user:u", "worked:worked-u", "assistant:answer", "turnSummary:end"]);
  // Opened, the fold holds every tool row of the turn, in order, and never the reply.
  expect(drawn(rows, new Set(["worked-u"]))).toEqual([
    "user:u",
    "worked:worked-u",
    "activity:defaults read",
    "activity:send",
    "assistant:answer",
    "turnSummary:end",
  ]);
});

test("the last reply stays open when short notes and tools come after it", () => {
  const rows = [
    row("u", "user"),
    tool("read"),
    reply("answer"),
    tool("grep", "execute"),
    text("checking one more thing"),
    tool("test", "execute"),
    summary(),
  ];
  const open = drawn(rows, new Set(["worked-u"]));
  expect(open.filter((entry) => entry.startsWith("activity:"))).toEqual([
    "activity:read",
    "activity:grep",
    "activity:test",
  ]);
  expect(open.slice(-2)).toEqual(["assistant:answer", "turnSummary:end"]);
  expect(drawn(rows)).toEqual(["user:u", "worked:worked-u", "assistant:answer", "turnSummary:end"]);
});

const dateTurn = (id: string, at: number, visible = true): AcpmuxRow[] => [
  { id, kind: "user", at, version: 1, text: visible ? "Prompt" : "" },
  { id: `${id}-answer`, kind: "assistant", at: at + 1_000, version: 1, text: visible ? "Answer" : "\u200B" },
  { id: `${id}-end`, kind: "turnSummary", at: at + 2_000, version: 1, status: "completed" },
];

test("an invisible turn across days leaves the separator for the next visible turn", () => {
  const start = Date.UTC(2026, 9, 30, 12);
  const nextDay = start + 24 * 3_600_000;
  const rows = [
    ...dateTurn("old", start),
    ...dateTurn("hidden", nextDay, false),
    ...dateTurn("next", nextDay + 60_000),
  ];
  const dates = turnView(rows, new Set(), { now: nextDay + 120_000 }).filter((row) => row.kind === "date");
  expect(dates.map((row) => row.id)).toEqual(["date-old", "date-next"]);
  expect(dates[1]!.at).toBe(nextDay + 60_000);
});

test("a reused invisible turn does not consume the next visible turn's separator", () => {
  const start = Date.UTC(2026, 9, 30, 12);
  const nextDay = start + 24 * 3_600_000;
  const folds = new Set<string>();
  const rows = [
    ...dateTurn("old", start),
    ...dateTurn("hidden", nextDay, false),
    ...dateTurn("hidden2", nextDay + 60_000, false),
  ];
  const previous = turnViewFrom(rows, folds, { now: nextDay + 120_000 });
  const appended = [...rows, ...dateTurn("next", nextDay + 120_000)];
  const updated = turnViewFrom(appended, folds, { now: nextDay + 180_000 }, previous);
  expect(updated.rows).toEqual(turnView(appended, folds, { now: nextDay + 180_000 }));
  expect(updated.rows.filter((row) => row.kind === "date").map((row) => row.id)).toEqual(["date-old", "date-next"]);
});

test("the first visible turn's separator ages even after an invisible first turn", () => {
  const start = Date.UTC(2026, 9, 30, 12);
  const folds = new Set<string>();
  const rows = [...dateTurn("hidden", start, false), ...dateTurn("next", start + 60_000)];
  const previous = turnViewFrom(rows, folds, { now: start + 120_000 });
  expect(previous.rows.some((row) => row.kind === "date")).toBe(false);
  const updated = turnViewFrom(rows, folds, { now: start + 2 * 3_600_000 }, previous);
  expect(updated.rows.filter((row) => row.kind === "date").map((row) => row.id)).toEqual(["date-next"]);
});
