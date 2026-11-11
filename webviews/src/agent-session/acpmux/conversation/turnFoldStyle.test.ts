// l10n-allow-file: test fixtures.
// One finished turn per harness family, folded as its table row says (turnFoldStyle.ts). Leo,
// 2026-11-04: "do it for chatgpt, do the proper folds for however the other harnessses/model
// families fold (muse, gemini)", then, on Claude: "you can't do it for Claude ... it's just too lossy
// if you do it for Claude". Lucas, 2026-11-06 (Codex parity): Claude, Gemini and Muse fold a finished
// turn under "Worked for" as Codex does; Claude's in-place runs are the experiment's `runs` arm.
import { afterEach, expect, test } from "bun:test";
import { SINCE_DIVIDER, type AcpmuxRow } from "../model";
import { WORKED, turnView } from "./turns";
import { CLAUDE_IN_PLACE, TURN_FOLD_STYLES, turnFoldStyle } from "./turnFoldStyle";

// Claude's older in-place arm, as the experiment's host override sets it (claudeTurnFold.experiment.ts).
const inPlace = () => {
  globalThis.cmuxExperiments = { "claude-turn-fold": "runs" };
};
afterEach(() => {
  delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
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
// Two runs of calls with a short note between them, then the conclusion.
const finished = [
  prompt,
  work("w1", 1_000, 2),
  say("n1", 10_000, "Checking the parser next."),
  work("w2", 20_000, 3),
  say("a", 50_000, "Done: the parser keeps the trailing comma now."),
  end,
];
// The same turn with a reply to the person between the runs: a takeaway, longer than a short note, so it
// stands between the runs instead of joining one (mergeShortNotes), and no fold hides it.
const replied = finished.map((row) => (row.id === "n1" ? say("n1", 10_000, NOTE) : row));
const drawn = (agentFamily: string, open: ReadonlySet<string> = new Set(), rows = finished) =>
  turnView(rows, open, { now: 70_000, agentFamily }).filter((row) => row.kind !== "user");
const ids = (rows: readonly AcpmuxRow[]) => rows.map((row) => row.id);

test("the table is the one place a family's fold is named", () => {
  expect(Object.keys(TURN_FOLD_STYLES).sort()).toEqual(["claude", "codex", "gemini", "muse"]);
  // Variants share their agent's row, and an unknown family folds as Codex does.
  expect(turnFoldStyle("claude-sr2")).toBe(TURN_FOLD_STYLES.claude!);
  expect(turnFoldStyle("muse-code")).toBe(TURN_FOLD_STYLES.muse!);
  expect(turnFoldStyle("opencode")).toBe(TURN_FOLD_STYLES.codex!);
  expect(turnFoldStyle(undefined)).toBe(TURN_FOLD_STYLES.codex!);
  // Claude folds a whole turn unless the in-place arm is on; no other family has that arm.
  expect(TURN_FOLD_STYLES.claude!.conclusion).toBe(true);
  expect(turnFoldStyle("claude", () => true)).toBe(CLAUDE_IN_PLACE);
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

test("claude, in place (older arm): no turn fold; each run on its own line in place, the prose between them", () => {
  inPlace();
  const rows = drawn("claude", new Set(), replied);
  expect(rows.some((row) => row.kind === WORKED)).toBe(false);
  expect(ids(rows.filter((row) => row.kind !== "turnSummary"))).toEqual(["w1", "n1", "w2", "a"]);
  expect(rows.filter((row) => row.kind === "activity").every((row) => row.foldRun === true)).toBe(true);
  expect(rows.find((row) => row.kind === "turnSummary")?.folded).toBe(false);
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

// Leo, 2026-11-06: "your intermediate message got lost. that can never happen" (turn-fold-keeps-replies.test.ts).
for (const family of ["claude", "codex", "gemini", "muse"])
  test(`${family}: a closed fold keeps a reply between two runs in sight, both runs under it`, () => {
    const rows = drawn(family, new Set(), replied);
    const worked = rows.find((row) => row.kind === WORKED)!;
    expect(worked.foldOpen).toBe(false);
    // The fold hides only calls, so no header counts messages.
    expect(worked.previous).toBeUndefined();
    // Every call stays under the closed line, as chatgpt.com draws it (turn-fold-hides-every-call.test.ts).
    expect(ids(rows.filter((row) => row.kind !== "turnSummary"))).toEqual([worked.id, "n1", "a"]);
  });

test("claude, opened: its runs fold per run with the chatter between them", () => {
  const closed = drawn("claude", new Set(), replied).find((row) => row.kind === WORKED)!;
  const rows = drawn("claude", new Set([closed.id]), replied);
  const runs = rows.filter((row) => row.kind === "activity");
  expect(runs.length).toBe(2);
  expect(runs.every((row) => row.foldRun === true)).toBe(true);
  expect(ids(rows)).toContain("n1");
});

test("claude: a turn that ends on a call keeps its last takeaway in sight, the call folded", () => {
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

test("the in-place arm leaves Codex, Gemini and Muse as their rows say", () => {
  inPlace();
  expect(drawn("codex").find((row) => row.kind === WORKED)?.previous).toBe(6);
  for (const family of ["gemini", "muse"]) expect(drawn(family).some((row) => row.kind === WORKED)).toBe(true);
});

for (const family of ["gemini", "muse"])
  test(`${family}: Worked for over the conclusion, no message count, the chatter and runs folded under it`, () => {
    const rows = drawn(family);
    const worked = rows.find((row) => row.kind === WORKED)!;
    expect(worked.foldOpen).toBe(false);
    expect(worked.previous).toBeUndefined();
    expect(ids(rows.filter((row) => row.kind !== "turnSummary"))).toEqual([worked.id, "a"]);
    expect(rows.find((row) => row.kind === "turnSummary")?.folded).toBe(true);
  });

// Leo, 2026-11-10: the divider read "sometimes under, sometimes above" a turn's "Worked for".
const since: AcpmuxRow = {
  id: SINCE_DIVIDER,
  version: 1,
  at: 0,
  kind: SINCE_DIVIDER,
  since: { key: "s:1", seq: 1, turns: 1 },
};
const opened = new Set([`${WORKED}-p`]);

test("New since you looked draws above Worked for wherever the person left the turn", () => {
  const places = [
    [prompt, since, work("w1", 1_000, 2), say("a", 50_000, "Done."), end],
    [prompt, work("w1", 1_000, 2), since, say("a", 50_000, "Done."), end],
    [prompt, work("w1", 1_000, 2), since, work("w2", 20_000, 1), say("a", 50_000, "Done."), end],
  ];
  for (const rows of places)
    for (const folds of [new Set<string>(), opened]) {
      const shown = ids(drawn("codex", folds, rows));
      expect(shown.indexOf(SINCE_DIVIDER)).toBe(shown.indexOf(`${WORKED}-p`) - 1);
    }
});

test("New since you looked goes above a Worked for with no reply after it, at the turn's end", () => {
  const shown = ids(drawn("codex", new Set(), [prompt, work("w1", 1_000, 1), end, since]));
  expect(shown.indexOf(SINCE_DIVIDER)).toBe(shown.indexOf(`${WORKED}-p`) - 1);
});

test("New since you looked stays under a reply the person read", () => {
  const shown = ids(drawn("codex", new Set(), [prompt, work("w1", 1_000, 1), say("a", 50_000, "Done."), end, since]));
  expect(shown.indexOf(SINCE_DIVIDER)).toBeGreaterThan(shown.indexOf("a"));
  expect(shown.indexOf(`${WORKED}-p`)).toBeLessThan(shown.indexOf("a"));
});
