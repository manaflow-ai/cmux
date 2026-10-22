// A finished turn folds its work under "Worked for", as the Codex and Claude desktop apps do, and
// its last reply stays open below the fold. A reply is never folded, also when the turn ran a tool
// after it (Leo, 2026-10-21, nightly 331e2e9: the final reply sat inside "Worked for 1m 7s";
// "Those replies should never be collapsed"); the tool after it folds with the rest. Only short
// interim notes the turn worked on after are status, and fold: a turn whose only text was such
// notes (or that stopped mid-tool) has no answer.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

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
