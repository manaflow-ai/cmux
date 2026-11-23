// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// A finished turn folds in the order it ran: a message that came in mid-turn ends the "Worked for"
// above it, and the work after it folds under its own line below it. Before, the turn drew one
// "Worked for" at its top, which pulled the work after the person's steer up above the steer (Leo,
// 2026-11-11: "it sort of, like, steals commands that came in, perhaps, like, in between something,
// and it just shunts them to the top, like it rewrites the transcript in a way").
// Gallery: agent-pane.one-fold-per-turn.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { backgroundTurnRowId } from "../src/agent-session/acpmux/conversation/backgroundTurns";
import { backgroundRunRowId } from "../src/agent-session/acpmux/conversation/backgroundRuns";
import { messageRunRowId } from "../src/agent-session/acpmux/conversation/messageRuns";
import {
  closeTurnRuns,
  NEXT_STEP,
  toggleTurnFold,
  turnFoldFor,
  turnInsideIds,
  turnView,
  WORKED,
} from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 11, 21, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const shell = (id: string, command: string): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: command, kind: "execute", status: "completed", command },
});
const calls = (id: string, second: number, commands: string[]): AcpmuxRow =>
  row(id, "activity", second, { items: commands.map((command, index) => shell(`${id}-${index}`, command)) });
const message = (id: string, second: number, name: string, text: string) =>
  row(id, "user", second, {
    text,
    continues: true,
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
  });

/// Six commands, a reply, the person's steer, two more commands, the answer.
const steered: AcpmuxRow[] = [
  row("u-0", "user", 0, { text: "Land the fold fix" }),
  calls("t-1", 1, ["cmux-ci build", "cmux-ci test", "git status", "git diff", "rg fold", "bun test a"]),
  row("a-before", "assistant", 120, { text: "Both builds are running. I'm reading the fold code meanwhile." }),
  row("s-1", "user", 130, { text: "Also check the nightly", steer: "landed" }),
  calls("t-2", 131, ["gh run list", "gh run view"]),
  row("a-final", "assistant", 300, { text: "The nightly is green and the fix is up for review." }),
  row("s-0", "turnSummary", 315, { status: "completed", durationMs: 315_000, toolCount: 8 }),
];

/// Another agent's message after a reply, then more work and the answer.
const messaged: AcpmuxRow[] = [
  row("u-0", "user", 0, { text: "Watch the nightly" }),
  calls("t-1", 1, ["gh run list"]),
  row("a-before", "assistant", 60, { text: "Watching it; I'll tell the owner when it's green." }),
  message("m-1", 90, "lane-box/ux-owner", "Is it green yet?"),
  calls("t-2", 91, ["gh run view 42", "gh pr view 7"]),
  row("a-final", "assistant", 200, { text: "Green; the owner is landing." }),
  row("s-0", "turnSummary", 210, { status: "completed", durationMs: 210_000, toolCount: 3 }),
];

const FAMILIES = ["claude", "codex", "gemini", "muse", undefined];
const view = (rows: AcpmuxRow[], family: string | undefined, expanded: ReadonlySet<string> = new Set()) =>
  turnView(rows, expanded, { agentFamily: family, now: START + 400_000 }).filter((shown) => shown.kind !== "date");
const ids = (rows: AcpmuxRow[]) => rows.filter((shown) => shown.kind !== "turnSummary").map((shown) => shown.id);

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

/// The reply before another agent's message stays in sight beside the closed fold
/// (turnFoldReplies `replies`), the only arms under which that message splits the fold.
const repliesInSight = () => {
  globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "turn-fold-replies": "replies" };
};

for (const family of FAMILIES)
  test(`${family ?? "an unknown family"}: no work after the steer draws above it`, () => {
    const closed = view(steered, family);
    expect(ids(closed)).toEqual(["u-0", `${WORKED}-u-0`, "a-before", "s-1", `${WORKED}-s-1`, "a-final"]);
    const [first, second] = closed.filter((shown) => shown.kind === WORKED);
    // Each fold times and counts its own stretch.
    expect(first!.durationMs).toBe(130_000);
    expect(second!.durationMs).toBe(185_000);
    expect(first!.toolCount).toBe(6);
    expect(second!.toolCount).toBe(2);
  });

for (const family of FAMILIES)
  test(`${family ?? "an unknown family"}: opening the fold after the steer opens it alone, in place`, () => {
    const expanded = toggleTurnFold(steered, new Set(), `${WORKED}-s-1`);
    expect([...expanded]).toEqual([`${WORKED}-s-1`]);
    const opened = view(steered, family, expanded);
    expect(ids(opened)).toEqual(["u-0", `${WORKED}-u-0`, "a-before", "s-1", `${WORKED}-s-1`, "t-2", "a-final"]);
    expect(opened.find((shown) => shown.id === `${WORKED}-u-0`)!.foldOpen).toBe(false);
    // Closing it again leaves the other fold as it was.
    const both = toggleTurnFold(steered, new Set([`${WORKED}-u-0`, `${WORKED}-s-1`]), `${WORKED}-s-1`);
    expect([...both]).toEqual([`${WORKED}-u-0`, `closed:${WORKED}-s-1`]);
  });

test("Find opens the fold that holds the match: the one after the steer for its commands", () => {
  expect(
    turnFoldFor(
      steered,
      steered.findIndex((shown) => shown.id === "t-1"),
    ),
  ).toBe(`${WORKED}-u-0`);
  expect(
    turnFoldFor(
      steered,
      steered.findIndex((shown) => shown.id === "t-2"),
    ),
  ).toBe(`${WORKED}-s-1`);
});

for (const family of ["codex", "claude"])
  test(`${family}: another agent's message after a reply opens the fold after it, folded in as its first entry`, () => {
    repliesInSight();
    const closed = view(messaged, family);
    expect(ids(closed)).toEqual(["u-0", `${WORKED}-u-0`, "a-before", `${WORKED}-m-1`, "a-final"]);
    const opened = view(messaged, family, new Set([`${WORKED}-m-1`]));
    // A received message draws on its own row or in a message run's line (messageRuns.ts).
    const at = (id: string) =>
      opened.findIndex((shown) => shown.id === id || (shown.messageRun?.rows ?? []).includes(id));
    expect(at("m-1")).toBeGreaterThan(at(`${WORKED}-m-1`));
    // The run after it joins the message's line (messageRuns.ts), or follows it.
    expect(at("t-2")).toBeGreaterThanOrEqual(at("m-1"));
    expect(
      turnFoldFor(
        messaged,
        messaged.findIndex((shown) => shown.id === "t-2"),
      ),
    ).toBe(`${WORKED}-m-1`);
  });

test("another agent's message with no reply before it folds in place, in the turn's one fold", () => {
  const quiet = messaged.filter((shown) => shown.id !== "a-before");
  expect(ids(view(quiet, "codex"))).toEqual(["u-0", `${WORKED}-u-0`, "a-final"]);
  expect(
    turnFoldFor(
      quiet,
      quiet.findIndex((shown) => shown.id === "t-2"),
    ),
  ).toBe(`${WORKED}-u-0`);
});

test("a message that draws nothing splits nothing: Find opens the fold the turn draws", () => {
  repliesInSight();
  const dot = messaged.map((shown) => (shown.id === "m-1" ? message("m-1", 90, "lane-box/ux-owner", ".") : shown));
  const drawn = view(dot, "codex");
  expect(drawn.filter((shown) => shown.kind === WORKED).map((shown) => shown.id)).toEqual([`${WORKED}-u-0`]);
  expect(
    turnFoldFor(
      dot,
      dot.findIndex((shown) => shown.id === "t-2"),
    ),
  ).toBe(`${WORKED}-u-0`);
});

test("a reply that draws nothing is no reply: Find opens the fold the turn draws", () => {
  repliesInSight();
  // An agent's message opens the turn, so its "." reply answers no person and draws nothing.
  const opener: AcpmuxRow = { ...message("u-0", 0, "lane-box/nightly", "Watch the nightly"), continues: undefined };
  const quiet = [opener, ...messaged.slice(1)].map((shown) =>
    shown.id === "a-before" ? { ...shown, text: "." } : shown,
  );
  const drawn = view(quiet, "codex");
  expect(drawn.filter((shown) => shown.kind === WORKED).map((shown) => shown.id)).toEqual([`${WORKED}-u-0`]);
  expect(
    turnFoldFor(
      quiet,
      quiet.findIndex((shown) => shown.id === "t-2"),
    ),
  ).toBe(`${WORKED}-u-0`);
});

test("a background turn's reply is no reply: the drawn fold and Find agree, opened or closed", () => {
  repliesInSight();
  // The agent's own turn after a tool's background task, its reply inside it (backgroundTurns.ts).
  const background = messaged.map((shown) => (shown.id === "a-before" ? { ...shown, inBackground: "bg-1" } : shown));
  const key = turnFoldFor(
    background,
    background.findIndex((shown) => shown.id === "t-2"),
  );
  for (const expanded of [new Set<string>(), new Set([backgroundTurnRowId("bg-1")])]) {
    const folds = view(background, "codex", expanded).filter((shown) => shown.kind === WORKED);
    expect(folds.map((shown) => shown.id)).toContain(key!);
    expect(folds.map((shown) => shown.id)).not.toContain(`${WORKED}-m-1`);
  }
});

test("a wrap-up after the steer draws its card once, under the answer before the steer", () => {
  const recap = "The fold fix is in review.";
  const wrap: AcpmuxRow = row("w-1", "activity", 290, {
    items: [
      {
        kind: "tool",
        text: "",
        tool: {
          id: "w-1-0",
          title: "mcp__acpmux__wrap_up",
          kind: "other",
          status: "completed",
          inputSummary: JSON.stringify({ recap, ask: "Merge it?", actions: ["Merge", "Not now"] }),
        },
      },
    ],
  });
  const answered: AcpmuxRow[] = [
    steered[0]!,
    steered[1]!,
    row("a-answer", "assistant", 120, {
      text: "The fix is up for review.\n\nBoth builds passed, and the nightly is next.",
    }),
    row("s-1", "user", 130, { text: "Also check the nightly", steer: "landed" }),
    steered[4]!,
    wrap,
    steered[6]!,
  ];
  for (const family of FAMILIES) {
    const cards = view(answered, family).filter((shown) => shown.kind === NEXT_STEP);
    expect(cards).toHaveLength(1);
  }
});

test("under Codex's reply fold (the default), another agent's message splits nothing: no two lines meet", () => {
  // The reply before it folds with the work (turnFoldReplies `answer`), so a split would draw the
  // prompt's Worked for right above the message's, nothing between them.
  const folds = view(messaged, "codex").filter((shown) => shown.kind === WORKED);
  expect(folds.map((shown) => shown.id)).toEqual([`${WORKED}-u-0`]);
  expect(
    turnFoldFor(
      messaged,
      messaged.findIndex((shown) => shown.id === "t-2"),
    ),
  ).toBe(`${WORKED}-u-0`);
  // The steer still splits: it and the reply before it stay in sight under every reply arm.
  expect(
    view(steered, "codex")
      .filter((shown) => shown.kind === WORKED)
      .map((shown) => shown.id),
  ).toEqual([`${WORKED}-u-0`, `${WORKED}-s-1`]);
});

test("a fold's click closes the lines inside it, not the next fold's", () => {
  repliesInSight();
  const lines = (id: string) => [messageRunRowId(id), backgroundRunRowId(id)];
  const opened = new Set([...lines("t-1"), ...lines("t-2"), ...lines("m-1")]);
  const first = new Set(opened);
  closeTurnRuns(messaged, first, `${WORKED}-u-0`);
  expect([...first].sort()).toEqual([...lines("t-2"), ...lines("m-1")].sort());
  const second = new Set(opened);
  closeTurnRuns(messaged, second, `${WORKED}-m-1`);
  expect([...second].sort()).toEqual(lines("t-1").sort());
  expect([...turnInsideIds(messaged, `${WORKED}-u-0`)]).toContain("t-1");
  expect([...turnInsideIds(messaged, `${WORKED}-u-0`)]).not.toContain("t-2");
  expect([...turnInsideIds(messaged, `${WORKED}-m-1`)]).toContain("t-2");
});

test("the one-fold arm keeps the turn's single Worked for at its top", () => {
  globalThis.cmuxExperiments = { "turn-fold-steered": "nested-open" };
  expect(ids(view(steered, "codex"))).toEqual(["u-0", `${WORKED}-u-0`, "a-before", "s-1", "a-final"]);
});
