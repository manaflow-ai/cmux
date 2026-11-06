// l10n-allow-file: test fixtures.
// One finished turn per harness family, folded as its table row says (turnFoldStyle.ts). Leo,
// 2026-11-04: "do it for chatgpt, do the proper folds for however the other harnessses/model
// families fold (muse, gemini)", then, on Claude: "you can't do it for Claude ... it's just too lossy
// if you do it for Claude", so Claude's whole-turn "Worked for" is an opt-in only.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { WORKED, turnView } from "./turns";
import { CLAUDE_WORKED_FOR, TURN_FOLD_STYLES, turnFoldStyle } from "./turnFoldStyle";

// Claude's opt-in, as the experiment's host override sets it (claudeTurnFold.experiment.ts).
const optIn = () => {
  globalThis.cmuxExperiments = { "claude-turn-fold": "worked-for" };
};
afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

const call = (id: string) => ({
  kind: "tool",
  text: "Run",
  tool: { id, title: "Run", kind: "execute", status: "completed" },
});
const prompt: AcpmuxRow = { id: "p", version: 1, at: 0, kind: "user", text: "Fix it" };
const work = (id: string, at: number, n: number) =>
  ({
    id,
    version: 1,
    at,
    kind: "activity",
    items: Array.from({ length: n }, (_, i) => call(`${id}-${i}`)),
  }) as AcpmuxRow;
const say = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });
const end: AcpmuxRow = {
  id: "s",
  version: 1,
  at: 60_000,
  kind: "turnSummary",
  status: "completed",
  durationMs: 60_000,
};
const NOTE =
  "Found the cause in the parser: it reads the trailing comma as the start of another item, so every list " +
  "that ends a line gets an empty entry, and the retry loop then treats that entry as a failed request.";
// Two runs of calls with chatter between them, then the conclusion.
const finished = [
  prompt,
  work("w1", 1_000, 2),
  // Longer than a short note, so it stands between the runs instead of joining one (mergeShortNotes).
  say("n1", 10_000, NOTE),
  work("w2", 20_000, 3),
  say("a", 50_000, "Done: the parser keeps the trailing comma now."),
  end,
];
const drawn = (agentFamily: string, open: ReadonlySet<string> = new Set()) =>
  turnView(finished, open, { now: 70_000, agentFamily }).filter((row) => row.kind !== "user");
const ids = (rows: readonly AcpmuxRow[]) => rows.map((row) => row.id);

test("the table is the one place a family's fold is named", () => {
  expect(Object.keys(TURN_FOLD_STYLES).sort()).toEqual(["claude", "codex", "gemini", "muse"]);
  // Variants share their agent's row, and an unknown family folds as Codex does.
  expect(turnFoldStyle("claude-sr2")).toBe(TURN_FOLD_STYLES.claude!);
  expect(turnFoldStyle("muse-code")).toBe(TURN_FOLD_STYLES.muse!);
  expect(turnFoldStyle("opencode")).toBe(TURN_FOLD_STYLES.codex!);
  expect(turnFoldStyle(undefined)).toBe(TURN_FOLD_STYLES.codex!);
  // Claude folds a whole turn only when opted in; no other family has the opt-in.
  expect(TURN_FOLD_STYLES.claude!.conclusion).toBe(false);
  expect(turnFoldStyle("claude", () => true)).toBe(CLAUDE_WORKED_FOR);
  expect(turnFoldStyle("codex", () => true)).toBe(TURN_FOLD_STYLES.codex!);
  expect(turnFoldStyle("gemini", () => true)).toBe(TURN_FOLD_STYLES.gemini!);
});

test("codex: one closed header over the conclusion, counting the messages it folds", () => {
  const rows = drawn("codex");
  const worked = rows.find((row) => row.kind === WORKED)!;
  expect(worked.foldOpen).toBe(false);
  expect(worked.previous).toBe(6);
  expect(ids(rows.filter((row) => row.kind !== "turnSummary"))).toEqual([worked.id, "a"]);
});

test("claude, by default: no turn fold; each run on its own line in place, the prose between them", () => {
  const rows = drawn("claude");
  expect(rows.some((row) => row.kind === WORKED)).toBe(false);
  expect(ids(rows.filter((row) => row.kind !== "turnSummary"))).toEqual(["w1", "n1", "w2", "a"]);
  expect(rows.filter((row) => row.kind === "activity").every((row) => row.foldRun === true)).toBe(true);
  expect(rows.find((row) => row.kind === "turnSummary")?.folded).toBe(false);
});

test("claude, opted in: Worked for over the conclusion, the chatter and runs folded under it", () => {
  optIn();
  const rows = drawn("claude");
  const worked = rows.find((row) => row.kind === WORKED)!;
  expect(worked.foldOpen).toBe(false);
  // ChatGPT's header: always "Worked for", never Codex's message count.
  expect(worked.previous).toBeUndefined();
  expect(worked.durationMs).toBe(60_000);
  expect(ids(rows.filter((row) => row.kind !== "turnSummary"))).toEqual([worked.id, "a"]);
  expect(rows.find((row) => row.kind === "turnSummary")?.folded).toBe(true);
});

test("claude, opted in and opened: its runs fold per run with the chatter between them", () => {
  optIn();
  const closed = drawn("claude").find((row) => row.kind === WORKED)!;
  const rows = drawn("claude", new Set([closed.id]));
  const runs = rows.filter((row) => row.kind === "activity");
  expect(runs.length).toBe(2);
  expect(runs.every((row) => row.foldRun === true)).toBe(true);
  expect(ids(rows)).toContain("n1");
});

test("claude, opted in: a turn that ends on a call keeps its last takeaway in sight, the call folded", () => {
  optIn();
  const takeaway = say(
    "t",
    30_000,
    "The parser drops the trailing comma when the list ends a line, which is why every request looked failed " +
      "to the retry loop; I'm sending the fix to the lane that owns the parser now and will check it lands.",
  );
  const rows = turnView([prompt, work("w1", 1_000, 2), takeaway, work("w2", 40_000, 1), end], new Set(), {
    now: 70_000,
    agentFamily: "claude",
  });
  const worked = rows.find((row) => row.kind === WORKED)!;
  expect(worked.foldOpen).toBe(false);
  expect(ids(rows.filter((row) => row.kind !== "turnSummary" && row.kind !== "user"))).toEqual([worked.id, "t"]);
});

test("claude, opted in: a turn with only its reply draws no Worked for", () => {
  optIn();
  const rows = turnView([prompt, say("a", 5_000, "Yes."), end], new Set(), { now: 70_000, agentFamily: "claude" });
  expect(rows.some((row) => row.kind === WORKED)).toBe(false);
  expect(ids(rows)).toContain("a");
});

test("claude, opted in: a running turn draws its work as it happens, no Worked for yet", () => {
  optIn();
  const rows = turnView([prompt, work("w1", 1_000, 2), say("n1", 10_000, "Looking.")], new Set(), {
    now: 20_000,
    agentFamily: "claude",
    working: true,
  });
  expect(rows.some((row) => row.kind === WORKED)).toBe(false);
  expect(ids(rows)).toContain("n1");
});

test("the opt-in leaves Codex, Gemini and Muse as their rows say", () => {
  optIn();
  expect(drawn("codex").find((row) => row.kind === WORKED)?.previous).toBe(6);
  for (const family of ["gemini", "muse"]) expect(drawn(family).some((row) => row.kind === WORKED)).toBe(false);
});

for (const family of ["gemini", "muse"])
  test(`${family}: no turn fold; each run folds into its own line in place, the chatter between them`, () => {
    const rows = drawn(family);
    expect(rows.some((row) => row.kind === WORKED)).toBe(false);
    const order = ids(rows.filter((row) => row.kind !== "turnSummary"));
    expect(order).toEqual(["w1", "n1", "w2", "a"]);
    expect(rows.filter((row) => row.kind === "activity").every((row) => row.foldRun === true)).toBe(true);
    expect(rows.find((row) => row.kind === "turnSummary")?.folded).toBe(false);
  });
