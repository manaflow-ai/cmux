// l10n-allow-file: test fixtures.
// One finished turn per harness family, folded as its table row says (turnFoldStyle.ts). Leo,
// 2026-11-04: "do it for chatgpt, do the proper folds for however the other harnessses/model
// families fold (muse, gemini)", then, on Claude: "i think it should be the top level collapsible
// thing IF POSSIBLE".
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { WORKED, turnView } from "./turns";
import { TURN_FOLD_STYLES, turnFoldStyle } from "./turnFoldStyle";

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
// Two runs of calls with chatter between them, then the conclusion.
const finished = [
  prompt,
  work("w1", 1_000, 2),
  say("n1", 10_000, "Found the cause in the parser."),
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
});

test("codex: one closed header over the conclusion, counting the messages it folds", () => {
  const rows = drawn("codex");
  const worked = rows.find((row) => row.kind === WORKED)!;
  expect(worked.foldOpen).toBe(false);
  expect(worked.previous).toBe(6);
  expect(ids(rows.filter((row) => row.kind !== "turnSummary"))).toEqual([worked.id, "a"]);
});

test("claude: Worked for over the conclusion, the chatter and runs folded under it", () => {
  const rows = drawn("claude");
  const worked = rows.find((row) => row.kind === WORKED)!;
  expect(worked.foldOpen).toBe(false);
  // ChatGPT's header: always "Worked for", never Codex's message count.
  expect(worked.previous).toBeUndefined();
  expect(worked.durationMs).toBe(60_000);
  expect(ids(rows.filter((row) => row.kind !== "turnSummary"))).toEqual([worked.id, "a"]);
  expect(rows.find((row) => row.kind === "turnSummary")?.folded).toBe(true);
});

test("claude: opened, its runs fold per run with the chatter between them, as Claude desktop's", () => {
  const closed = drawn("claude").find((row) => row.kind === WORKED)!;
  const rows = drawn("claude", new Set([closed.id]));
  const runs = rows.filter((row) => row.kind === "activity");
  expect(runs.length).toBe(2);
  expect(runs.every((row) => row.foldRun === true)).toBe(true);
  expect(ids(rows)).toContain("n1");
});

test("claude: a turn that ends on a call keeps its last takeaway in sight, the call folded", () => {
  const takeaway = say(
    "t",
    30_000,
    "The parser drops the trailing comma when the list ends a line; I'm sending the fix to the lane now.",
  );
  const rows = turnView([prompt, work("w1", 1_000, 2), takeaway, work("w2", 40_000, 1), end], new Set(), {
    now: 70_000,
    agentFamily: "claude",
  });
  const worked = rows.find((row) => row.kind === WORKED)!;
  expect(worked.foldOpen).toBe(false);
  expect(ids(rows.filter((row) => row.kind !== "turnSummary" && row.kind !== "user"))).toEqual([worked.id, "t"]);
});

test("claude: a turn with only its reply draws no Worked for", () => {
  const rows = turnView([prompt, say("a", 5_000, "Yes."), end], new Set(), { now: 70_000, agentFamily: "claude" });
  expect(rows.some((row) => row.kind === WORKED)).toBe(false);
  expect(ids(rows)).toContain("a");
});

test("claude: a running turn draws its work as it happens, no Worked for yet", () => {
  const rows = turnView([prompt, work("w1", 1_000, 2), say("n1", 10_000, "Looking.")], new Set(), {
    now: 20_000,
    agentFamily: "claude",
    working: true,
  });
  expect(rows.some((row) => row.kind === WORKED)).toBe(false);
  expect(ids(rows)).toContain("n1");
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
