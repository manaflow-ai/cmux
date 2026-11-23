// l10n-allow-file: test fixture text, not shipped UI.
// A finished turn folds to its reply and one "Worked for", whatever started it (cmux#49592: "sometimes
// we are still showing too much tool calls and stuff, it's not fully collapsed"). A turn the agent ran
// on its own after a background task or a subagent finished drew every run of calls, its thinking and
// its wrap-up call as rows beside its reply, while the person's turns above folded theirs. The shape
// is the coordinator's chat in the report: a prompt's turn, then wake turns, each with calls, short
// notes and a reply, the last one still running.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { hiddenRowFolds, toggleTurnFold, turnView } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const calls = (id: string, titles: string[], inBackground?: string) =>
  row(id, "activity", {
    ...(inBackground && { inBackground }),
    toolCount: titles.length,
    items: titles.map((title, index) => ({
      kind: "tool" as const,
      text: title,
      tool: { id: `${id}-${index}`, title, kind: "execute", status: "completed" },
    })),
  });
const woke = (id: string, cause: NonNullable<AcpmuxRow["background"]>["cause"], extra = {}) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    background: { id, trigger: "task_notification", running: false, quiet: false, hasRows: true, cause, ...extra },
  });
const shell = (summary: string) => ({ kind: "shell", status: "completed", weight: "result" as const, summary });
const subagent = (summary: string) => ({ kind: "subagent", status: "completed", weight: "result" as const, summary });

/// The person's turn, a subagent's report and a background task's end that each woke the agent, and
/// (`running`) a third wake still at work.
function chat(running = false): AcpmuxRow[] {
  at = 0;
  const rows = [
    row("prompt", "user", { text: "Push the fix and start the fleet tests" }),
    calls("push", ["git push", "cmux-ci test"]),
    row("pushed", "assistant", { text: "The new head is pushed and the fleet tests started." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 18_000, seq: 10, toolCount: 2 }),
    woke("review", subagent("Re-review hand-off ask ahead finished")),
    calls("review-read", ["gh pr view", "rg ask", "sed -n 1,80p"], "review"),
    row("review-note", "assistant", { text: "Reading the review.", inBackground: "review" }),
    calls("review-fix", ["git commit", "git push"], "review"),
    row("review-reply", "assistant", { text: "Fixed the one should-fix and pushed it.", inBackground: "review" }),
    row("review-summary", "turnSummary", {
      status: "completed",
      durationMs: 9_000,
      seq: 20,
      toolCount: 5,
      inBackground: "review",
    }),
    woke("build", shell("Background task finished: Dev build m of the scratch tree")),
    calls("build-check", ["cmux-ci status", "tail build.log", "curl backend"], "build"),
    row("build-reply", "assistant", {
      text: "Transient: the backend answers now. Resubmitting.",
      inBackground: "build",
    }),
    calls("build-again", ["cmux-ci submit"], "build"),
    row("build-wait", "assistant", { text: "The build will bring me back when it ends.", inBackground: "build" }),
    row("build-summary", "turnSummary", {
      status: "completed",
      durationMs: 6_000,
      seq: 30,
      toolCount: 4,
      inBackground: "build",
    }),
  ];
  if (running)
    rows.push(
      woke("install", shell("Background task finished: Rerun build m's install"), { running: true, quiet: undefined }),
      row("install-note", "assistant", { text: "Installed. Launching and checking sign-in.", inBackground: "install" }),
      calls("install-launch", ["bash launch-verify.sh"], "install"),
    );
  return rows;
}

const WORK = ["review-read", "review-fix", "build-check", "build-again"];
const drawnIds = (rows: readonly AcpmuxRow[]) => rows.map((entry) => entry.id);

for (const agentFamily of ["claude", "codex", undefined])
  test(`${agentFamily ?? "default"}: each finished wake turn folds its work under one closed Worked for`, () => {
    const view = turnView(chat(), new Set(), { now: 60_000, agentFamily });
    const ids = drawnIds(view);
    // No call of a finished wake turn draws at rest.
    for (const id of WORK) expect(ids).not.toContain(id);
    for (const background of ["review", "build"]) {
      const worked = view.filter((entry) => entry.id === `worked-${backgroundTurnRowId(background)}`);
      expect(worked).toHaveLength(1);
      expect(worked[0]).toMatchObject({ kind: "worked", foldOpen: false, status: "completed" });
    }
    // Each one's final reply stays in sight, under its line.
    expect(ids.indexOf("review-reply")).toBeGreaterThan(ids.indexOf(`worked-${backgroundTurnRowId("review")}`));
    expect(ids.indexOf("build-wait")).toBeGreaterThan(ids.indexOf(`worked-${backgroundTurnRowId("build")}`));
    // Each one keeps its footer, with its reply to copy.
    expect(view.find((entry) => entry.id === "build-summary")).toMatchObject({
      kind: "turnSummary",
      text: "The build will bring me back when it ends.",
    });
  });

test("the finished wake turns fold the same while a later one runs", () => {
  const idle = turnView(chat(), new Set(), { now: 60_000, agentFamily: "claude" });
  const running = turnView(chat(true), new Set(), { now: 90_000, agentFamily: "claude", working: true });
  const settled = (rows: readonly AcpmuxRow[]) => drawnIds(rows).slice(0, drawnIds(rows).indexOf("build-summary") + 1);
  expect(settled(running)).toEqual(settled(idle));
  for (const id of WORK) expect(drawnIds(running)).not.toContain(id);
  // The running one is not folded yet: its work shows as it happens, on its live line.
  expect(drawnIds(running)).not.toContain(`worked-${backgroundTurnRowId("install")}`);
});

test("opening a wake turn's Worked for shows its work, and closing it folds it again", () => {
  const rows = chat();
  const id = `worked-${backgroundTurnRowId("build")}`;
  const opened = toggleTurnFold(rows, new Set(), id);
  const view = turnView(rows, opened, { now: 60_000, agentFamily: "claude" });
  expect(view.find((entry) => entry.id === id)).toMatchObject({ foldOpen: true });
  expect(drawnIds(view)).toContain("build-check");
  // Only that turn opens: the subagent's wake stays folded.
  expect(drawnIds(view)).not.toContain("review-read");
  const closed = toggleTurnFold(rows, opened, id);
  expect(drawnIds(turnView(rows, closed, { now: 60_000, agentFamily: "claude" }))).not.toContain("build-check");
});

test("Find opens the Worked for that hides a wake turn's call", () => {
  const rows = chat();
  const drawn = turnView(rows, new Set(), { now: 60_000, agentFamily: "claude" });
  const folds = hiddenRowFolds(
    rows,
    drawn,
    rows.findIndex((entry) => entry.id === "review-read"),
  );
  expect(folds[0]).toBe(`worked-${backgroundTurnRowId("review")}`);
  const view = turnView(rows, new Set(folds), { now: 60_000, agentFamily: "claude" });
  expect(drawnIds(view)).toContain("review-read");
});

test("what comes between the wake turns stays in sight: a compaction, a command's card, the message that woke one", () => {
  // From a replay of the report's chat: each of these sat between one wake turn's footer and the next
  // turn's own rows, drew there before, and was lost in the next turn's fold.
  const rows = chat();
  const compaction = row("compaction", "compaction", { compaction: { state: "completed" } });
  const card = row("card", "backgroundTask", {
    backgroundTask: { toolCallId: "t-card", command: "Locate the schema fields", state: "stopped" },
  });
  // Another chat's message, steered into the turn it woke.
  const message = row("message", "user", {
    text: "not mine: I never wrote in that branch",
    incoming: { kind: "message", message: { name: "fork-7", text: "not mine", raw: "not mine" } },
    steer: "landed",
  });
  rows.splice(rows.findIndex((entry) => entry.id === backgroundTurnRowId("build")), 0, compaction, card);
  rows.splice(rows.findIndex((entry) => entry.id === backgroundTurnRowId("build")) + 1, 0, message);
  const ids = drawnIds(turnView(rows, new Set(), { now: 60_000, agentFamily: "claude" }));
  for (const id of ["compaction", "card", "message"]) expect(ids).toContain(id);
  // The turn after them still folds its work.
  for (const id of WORK) expect(ids).not.toContain(id);
  expect(ids.indexOf("message")).toBeLessThan(ids.indexOf(`worked-${backgroundTurnRowId("build")}`));
});

test("a stopped wake turn's Worked for draws open, and a click closes it", () => {
  // As a stopped turn the person started: its work stays in sight until a click folds it. From a
  // replay of a recorded chat, where the click on a stopped wake turn's fold did nothing.
  const rows = chat().map((entry) => (entry.id === "build-summary" ? { ...entry, status: "cancelled" } : entry));
  const id = `worked-${backgroundTurnRowId("build")}`;
  const view = (folds: ReadonlySet<string>) => turnView(rows, folds, { now: 60_000, agentFamily: "claude" });
  const rest = view(new Set());
  expect(rest.find((entry) => entry.id === id)).toMatchObject({ foldOpen: true });
  expect(drawnIds(rest)).toContain("build-check");
  const closed = toggleTurnFold(rows, new Set(), id);
  expect(view(closed).find((entry) => entry.id === id)).toMatchObject({ foldOpen: false });
  expect(drawnIds(view(closed))).not.toContain("build-check");
  const reopened = toggleTurnFold(rows, closed, id);
  expect(view(reopened).find((entry) => entry.id === id)).toMatchObject({ foldOpen: true });
});
