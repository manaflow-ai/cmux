// l10n-allow-file: test fixtures, not shipped UI.
// The person's steer ends the part of the turn before it for the reader, so that part gets the Copy an
// ended turn's footer has, in the gap over the steer, as Claude Code does when the person comes in
// (Leo, 2026-11-03: "a lot of these should've been counted as "ended"-ish turns that allow me to
// copy/paste your stuff / cuz look claude code lets that happen if the user comes in"). His capture: a
// reply, "Ran 4 commands" under it, then his "ofc".
import { expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { turnCopyText } from "./turnCopy";
import { turnView, WORKED } from "./turns";

const t = translatorFor("en");
const ASK = "All three are contained Rust changes. Want me to put a lane on them, starting with the seed?";
const run = (id: string): AcpmuxActivity => ({
  kind: "tool",
  text: "git status",
  tool: { id, title: "git status", kind: "execute", status: "completed", command: "git status" },
});
const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}) =>
  ({ id, version: 1, at, kind, ...extra }) as AcpmuxRow;
const source = [
  row("u1", "user", 0, { text: "Which are worth doing?" }),
  row("a1", "assistant", 1_000, { text: ASK }),
  row("t1", "activity", 2_000, { items: [run("c1"), run("c2")], toolCount: 2 }),
  row("s1", "user", 3_000, { text: "ofc", steer: "landed" }),
  row("t2", "activity", 3_500, { items: [run("c3")], toolCount: 1 }),
  row("a2", "assistant", 4_000, { text: "Started the seed lane." }),
];
const ended = [...source, row("f1", "turnSummary", 5_000, { durationMs: 5_000, toolCount: 3, status: "completed" })];
const copyOf = (rows: readonly AcpmuxRow[], id: string) => {
  const parts = rows.find((one) => one.id === id)?.segmentCopy;
  return parts && turnCopyText(t, parts);
};

test("the person's steer carries the copy of the part of the turn before it, its work included", () => {
  const running = turnView(source, new Set(), { now: 10_000, working: true });
  expect(copyOf(running, "s1")).toBe([ASK, "Ran 2 commands"].join("\n\n"));
  for (const expanded of [new Set<string>(), new Set([`${WORKED}-u1`])])
    expect(copyOf(turnView(ended, expanded, { now: 10_000 }), "s1")).toBe([ASK, "Ran 2 commands"].join("\n\n"));
  // The turn's own footer still copies the whole turn.
  const footer = turnView(ended, new Set(), { now: 10_000 }).find((one) => one.kind === "turnSummary")!;
  expect(turnCopyText(t, footer.turnCopy!)).toContain("Started the seed lane.");
});

test("a second steer copies only what came after the first", () => {
  const rows = turnView([...source, row("s2", "user", 4_500, { text: "and the packs", steer: "landed" })], new Set(), {
    now: 10_000,
    working: true,
  });
  const parts = rows.find((one) => one.id === "s2")!.segmentCopy!;
  expect(parts.length).toBe(2);
  expect("tools" in parts[0]! && parts[0].tools.map((item) => item.tool?.id)).toEqual(["c3"]);
  expect(parts[1]).toEqual({ text: "Started the seed lane." });
});

test("no copy where nothing was said, nor on a prompt or another agent's message", () => {
  const quiet = turnView(
    [
      row("u1", "user", 0, { text: "go" }),
      row("t1", "activity", 1_000, { items: [run("c1")], toolCount: 1 }),
      source[3]!,
    ],
    new Set(),
    { now: 10_000, working: true },
  );
  expect(copyOf(quiet, "s1")).toBeUndefined();
  const rows = turnView(ended, new Set(), { now: 10_000 });
  expect(copyOf(rows, "u1")).toBeUndefined();
  const message = turnView(
    source.map((one) =>
      one.id === "s1"
        ? {
            ...one,
            steer: undefined,
            incoming: { kind: "message", message: { name: "lane-12", sessionId: "lane-12", text: "ofc", raw: "ofc" } },
          }
        : one,
    ) as AcpmuxRow[],
    new Set(),
    { now: 10_000, working: true },
  );
  expect(copyOf(message, "s1")).toBeUndefined();
});

test("the steer draws again when a row its copy is read from changes", () => {
  const steer = (rows: readonly AcpmuxRow[]) =>
    turnView(rows, new Set(), { now: 10_000, working: true }).find((one) => one.id === "s1")!;
  const before = steer(source);
  const edited = source.map((one) => (one.id === "a1" ? { ...one, version: 2, text: `${ASK} Or not.` } : one));
  const after = steer(edited);
  expect(turnCopyText(t, after.segmentCopy!)).toContain("Or not.");
  expect(after.version).not.toBe(before.version);
  // The same rows give the same version, so an unchanged steer keeps its memo.
  expect(steer(source).version).toBe(before.version);
});
