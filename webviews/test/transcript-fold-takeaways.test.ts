// A finished turn folds only its work: tool rows, thoughts, compactions, where a subagent ended and
// short narration ("Let me check…"). A reply that reads as a takeaway stays in sight wherever it is
// in the turn, and so does the turn's final reply; the work between two takeaways folds on its own
// between them, so a turn reads [fold][takeaway][fold][takeaway]. Leo, 2026-10-21: "we dont want
// end of turn takeaway responses to be folded in im pretty sure..."; "is there a true final
// takeaway that we can keep?". Lawrence: "this stuff needs to be collapsed".
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { isTakeaway, turnFoldFor, turnView } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const ran = (id: string) =>
  row(id, "activity", {
    items: [{ kind: "tool", text: "", tool: { id, title: id, kind: "execute", status: "completed" } }],
  });
const say = (id: string, text: string) => row(id, "assistant", { text });
/// A user-facing answer with a list, as in Leo's screenshot (synthetic text).
const answer = (id: string) =>
  say(
    id,
    `${id}: the import moves your shell history, bookmarks and themes into the app.\n\nTwo things for you:\n1. Pick the profile to import.\n2. Say whether to keep the old one.`,
  );
const summary = (id = "end") => row(id, "turnSummary", { status: "completed", durationMs: 9_000 });

const drawn = (rows: AcpmuxRow[], expanded: ReadonlySet<string> = new Set(), working = false) =>
  turnView(rows, expanded, { working })
    .filter((shaped) => shaped.kind !== "date")
    .map((shaped) => `${shaped.kind}:${shaped.id}`);

/// Leo's shape: four commands, an answer with a list, two commands, an answer.
const leosTurn = () => [
  row("u", "user"),
  ran("ran-1"),
  ran("ran-2"),
  ran("ran-3"),
  ran("ran-4"),
  answer("first"),
  ran("ran-5"),
  ran("ran-6"),
  answer("second"),
  summary(),
];

test("both answers of Leo's turn stay in sight; each run of commands folds on its own", () => {
  expect(drawn(leosTurn())).toEqual([
    "user:u",
    "worked:worked-u",
    "assistant:first",
    "worked:worked-first",
    "assistant:second",
    "turnSummary:end",
  ]);
});

test("each fold opens to its own commands, in order", () => {
  expect(drawn(leosTurn(), new Set(["worked-first"]))).toEqual([
    "user:u",
    "worked:worked-u",
    "assistant:first",
    "worked:worked-first",
    "activity:ran-5",
    "activity:ran-6",
    "assistant:second",
    "turnSummary:end",
  ]);
  expect(drawn(leosTurn(), new Set(["worked-u"])).slice(1, 7)).toEqual([
    "worked:worked-u",
    "activity:ran-1",
    "activity:ran-2",
    "activity:ran-3",
    "activity:ran-4",
    "assistant:first",
  ]);
});

test("Find opens the fold that holds the row", () => {
  const rows = leosTurn();
  expect(
    turnFoldFor(
      rows,
      rows.findIndex((entry) => entry.id === "ran-2"),
    ),
  ).toBe("worked-u");
  expect(
    turnFoldFor(
      rows,
      rows.findIndex((entry) => entry.id === "ran-6"),
    ),
  ).toBe("worked-first");
});

test("short narration between tools folds with them", () => {
  const rows = [
    row("u", "user"),
    ran("read"),
    say("check", "Let me check the host next."),
    ran("grep"),
    say("running", "Both audits still running."),
    ran("test"),
    answer("final"),
    summary(),
  ];
  expect(drawn(rows)).toEqual(["user:u", "worked:worked-u", "assistant:final", "turnSummary:end"]);
  expect(drawn(rows, new Set(["worked-u"]))).toContain("assistant:check");
});

test("long reply, then a tool, then 'Pushed.': both stay in sight and the tool folds between them", () => {
  const rows = [row("u", "user"), ran("read"), answer("reply"), ran("git push"), say("pushed", "Pushed."), summary()];
  expect(drawn(rows)).toEqual([
    "user:u",
    "worked:worked-u",
    "assistant:reply",
    "worked:worked-reply",
    "assistant:pushed",
    "turnSummary:end",
  ]);
});

test("compactions and finished subagents fold with the work; an error stays in sight", () => {
  const rows = [
    row("u", "user"),
    ran("read"),
    row("compacted", "compaction", { compaction: { state: "completed", preTokens: 123_000, postTokens: 13_000 } }),
    row("cef-done", "subagentDone", { text: "CEF audit" }),
    row("refused", "notice", { text: "The prompt was refused" }),
    answer("final"),
    summary(),
  ];
  expect(drawn(rows)).toEqual(["user:u", "worked:worked-u", "notice:refused", "assistant:final", "turnSummary:end"]);
});

test("a running turn draws as before: nothing folds", () => {
  const shaped = drawn(leosTurn().slice(0, -1), new Set(), true);
  expect(shaped.filter((entry) => entry.startsWith("worked:"))).toEqual([]);
  expect(shaped).toContain("assistant:first");
});

test("a turn with only its answer draws no fold", () => {
  expect(drawn([row("u", "user"), answer("only"), summary()])).toEqual(["user:u", "assistant:only", "turnSummary:end"]);
});

test("an empty last message never takes the answer's place", () => {
  const rows = [row("u", "user"), ran("read"), answer("reply"), ran("push"), say("empty", " "), summary()];
  const shaped = drawn(rows);
  expect(shaped.slice(0, 3)).toEqual(["user:u", "worked:worked-u", "assistant:reply"]);
  expect(shaped).not.toContain("assistant:empty");
});

test("what reads as a takeaway: long prose, a question, a list or a link; not short narration", () => {
  expect(isTakeaway(say("a", "Let me check…"))).toBe(false);
  expect(isTakeaway(say("b", "Both audits still running."))).toBe(false);
  expect(isTakeaway(say("c", "Should I also bump the timeout?"))).toBe(true);
  expect(isTakeaway(say("d", "Done:\n- one\n- two"))).toBe(true);
  expect(isTakeaway(say("e", "Opened [#123](https://example.com/123)."))).toBe(true);
  expect(isTakeaway(say("f", "word ".repeat(60)))).toBe(true);
  expect(isTakeaway(say("g", "one\ntwo\nthree\nfour"))).toBe(true);
});

test("Find opens the right fold past a prompt that failed to send mid-turn", () => {
  const rows = [
    row("u", "user"),
    ran("tool1"),
    answer("longA"),
    row("p", "user", { text: "also this", failed: true }),
    ran("tool2"),
    answer("longB"),
    summary(),
  ];
  expect(drawn(rows).filter((entry) => entry.startsWith("worked:"))).toEqual([
    "worked:worked-u",
    "worked:worked-longA",
  ]);
  expect(
    turnFoldFor(
      rows,
      rows.findIndex((entry) => entry.id === "tool2"),
    ),
  ).toBe("worked-longA");
  expect(
    turnFoldFor(
      rows,
      rows.findIndex((entry) => entry.id === "tool1"),
    ),
  ).toBe("worked-u");
});

test("a stopped turn says so on its last Worked for, also when its last stretch has no work", () => {
  const stopped = (rows: AcpmuxRow[]) =>
    turnView([...rows, row("end", "turnSummary", { status: "cancelled", durationMs: 9_000 })], new Set())
      .filter((shaped) => shaped.kind === "worked")
      .map((shaped) => `${shaped.id}:${shaped.status ?? ""}`);
  // The last stretch folds the work between the first answer and the closing line.
  expect(stopped([row("u", "user"), ran("a"), answer("first"), ran("b"), say("tail", "Stopping here.")])).toEqual([
    "worked-u:",
    "worked-first:cancelled",
  ]);
  // The last stretch is only the answer: the fold before it carries the stop.
  expect(stopped([row("u", "user"), ran("a"), answer("first"), say("tail", "Stopping here.")])).toEqual([
    "worked-u:cancelled",
  ]);
});

test("Find opens the right fold for a row after a summary a steer continued", () => {
  const rows = [
    row("u", "user"),
    ran("tool1"),
    answer("longA"),
    row("cut", "turnSummary", { status: "cancelled", continued: true }),
    ran("tool2"),
    answer("longB"),
    row("s1", "user", { text: "and the tests", steer: "landed" }),
    ran("tool3"),
    answer("longC"),
    summary(),
  ];
  const folds = drawn(rows).filter((entry) => entry.startsWith("worked:"));
  expect(folds).toEqual(["worked:worked-u", "worked:worked-longA", "worked:worked-s1"]);
  expect(
    turnFoldFor(
      rows,
      rows.findIndex((entry) => entry.id === "tool2"),
    ),
  ).toBe("worked-longA");
  expect(
    turnFoldFor(
      rows,
      rows.findIndex((entry) => entry.id === "tool3"),
    ),
  ).toBe("worked-s1");
});

test("a code block keeps a reply in sight; a note naming a file inline still folds", () => {
  expect(isTakeaway(say("fence", "~~~\nbun test\n~~~"))).toBe(true);
  expect(isTakeaway(say("ticks", "```\nbun test\n```"))).toBe(true);
  expect(isTakeaway(say("inline", "Reading `client.ts` next."))).toBe(false);
});
