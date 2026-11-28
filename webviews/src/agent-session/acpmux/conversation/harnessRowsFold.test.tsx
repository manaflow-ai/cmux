// l10n-allow-file: test fixture prompts, notices and agent names, not shipped UI.
// Rows the harness writes into a turn are tool-call work of the turn they arrive in, by their origin,
// never by their text: a task notification (marked `lineOrigin: "task-notification"`, or a legacy
// one known by its envelope), another session's message (`lineOrigin: "peer"`), acpmux's inbox relay,
// a subagent's "Report from" line. Leo, 2026-11-24: "we can initiate the Worked for with these
// background tasks as actual tool calls. we can indeed treat them as tool calls, even though they're
// bursted at the end/start of turns. thereby we can have them be folded properly too."
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { backgroundRunLabel, harnessWork } from "./backgroundRuns";
import { surgeOfEvent } from "./surgeHold";
import { turnView, WORKED } from "./turns";
import { translate } from "../i18n";

const START = Date.UTC(2026, 10, 24, 1, 0, 0);
const row = (id: string, kind: string, second: number, extra: Record<string, unknown> = {}): AcpmuxRow =>
  ({ id, kind, version: 1, at: START + second * 1000, ...extra }) as AcpmuxRow;
const steerIn = { steer: "landed" };
/// A task notification Claude Code wrote into the turn, as acpmux marked it (or, `legacy`, not).
const notification = (index: number, legacy = false): AcpmuxRow =>
  row(`n-${index}`, "user", 400 + index, {
    ...steerIn,
    text: `<task-notification><summary>Agent "lane ${index}" completed</summary></task-notification>`,
    incoming: {
      kind: "notice",
      text: `Agent "lane ${index}" completed`,
      ...(!legacy && { lineOrigin: "task-notification" }),
    },
  });
const peer = (index: number, extra: Record<string, unknown> = {}): AcpmuxRow =>
  row(`p-${index}`, "user", 450 + index, {
    ...steerIn,
    text: "Lane is green.",
    incoming: {
      kind: "message",
      message: { name: `lane-${index}`, text: "Lane is green.", raw: "Lane is green.", lineOrigin: "peer", ...extra },
    },
  });
const inbox = (index: number): AcpmuxRow =>
  row(`i-${index}`, "user", 470 + index, {
    ...steerIn,
    text: "inbox",
    incoming: {
      kind: "inbox",
      notice: {
        threads: [
          { id: `t-${index}`, label: "", from: ["lane-x"], count: 2, preview: "done", blocker: false, promptIds: [] },
        ],
      },
    },
  });
/// A subagent's "Report from" line: the line of the background turn its task notification started.
const report = (index: number, quiet = true): AcpmuxRow =>
  row(`backgroundTurn-r${index}`, "backgroundTurn", 490 + index, {
    background: {
      id: `r${index}`,
      trigger: "task_notification",
      running: false,
      quiet,
      ...(!quiet && { hasRows: true }),
      cause: { kind: "subagent", status: "completed", weight: "result", summary: `helper-${index} finished` },
    },
  });
const work = row("t-1", "activity", 1, {
  items: [{ kind: "tool", text: "", tool: { id: "c1", title: "bun test", kind: "execute", status: "completed" } }],
});

/// A prompt, work, the person's steer, the agent's reply, then what the harness wrote after it.
const steered = (burst: AcpmuxRow[]): AcpmuxRow[] => [
  row("u-0", "user", 0, { text: "Land the lanes" }),
  work,
  row("s-1", "user", 100, { text: "Also check lane 9", ...steerIn }),
  row("a-1", "assistant", 300, { text: "Checked; lane 9 is green." }),
  row("sum", "turnSummary", 310, { status: "completed", durationMs: 310_000, toolCount: 1 }),
  ...burst,
];
const view = (rows: AcpmuxRow[], expanded: ReadonlySet<string> = new Set()) =>
  turnView(rows, expanded, { agentFamily: "claude", now: START + 900_000 }).filter((r) => r.kind !== "date");
const ids = (rows: AcpmuxRow[]) => rows.map((r) => r.id);
/// The view with the turn's fold opened, and that fold: the last "Worked for" over the answer (the
/// late steer draws under it and over the answer, `lateSteersLast`).
const opened = (rows: AcpmuxRow[]) => {
  const closed = view(rows);
  const fold = [...closed].reverse().find((r) => r.kind === WORKED && closed.indexOf(r) < ids(closed).indexOf("a-1"));
  expect(fold).toBeDefined();
  return { closed, fold: fold!, open: view(rows, new Set([fold!.id])) };
};
/// `open` with its run of messages between agents opened too (messageRuns.ts groups them in the fold).
const messagesOpen = (rows: AcpmuxRow[], open: AcpmuxRow[]) =>
  view(rows, new Set(open.filter((r) => r.kind === WORKED || r.id.startsWith("messageRun-")).map((r) => r.id)));
const label = (line: AcpmuxRow) =>
  renderToStaticMarkup(<BackgroundTurnLine row={line} expanded={false} onToggle={() => {}} />);

test("task notifications marked by their origin after a steer fold under its Worked for and group as one count", () => {
  const rows = steered(Array.from({ length: 5 }, (_, i) => notification(i)));
  const { closed, fold, open } = opened(rows);
  expect(ids(closed).filter((id) => id.startsWith("n-"))).toEqual([]);
  // The burst came after the answer: the answer stays last, as for a call after it.
  expect(ids(closed).indexOf(fold.id)).toBeLessThan(ids(closed).indexOf("a-1"));
  const line = open.find((r) => r.backgroundRun);
  expect(line?.backgroundRun).toMatchObject({ notifications: 5 });
  expect(label(line!)).toContain("5 task notifications");
  const all = view(rows, new Set([fold.id, line!.id]));
  expect(ids(all).filter((id) => id.startsWith("n-"))).toHaveLength(5);
});

test("a legacy task notification with no origin folds the same way", () => {
  const rows = steered([notification(0, true), notification(1, true), notification(2, true)]);
  const { closed, open } = opened(rows);
  expect(ids(closed).filter((id) => id.startsWith("n-"))).toEqual([]);
  expect(open.find((r) => r.backgroundRun)?.backgroundRun).toMatchObject({ notifications: 3 });
});

test("peer messages fold into the Worked for; alone they stay the received messages they were", () => {
  const rows = steered([peer(0), peer(1)]);
  const { closed, open } = opened(rows);
  expect(ids(closed).filter((id) => id.startsWith("p-"))).toEqual([]);
  expect(ids(messagesOpen(rows, open))).toEqual(expect.arrayContaining(["p-0", "p-1"]));
  expect(open.some((r) => r.backgroundRun)).toBe(false);
});

test("an inbox relay folds into the Worked for", () => {
  const rows = steered([inbox(0)]);
  const { closed, open } = opened(rows);
  expect(ids(closed)).not.toContain("i-0");
  expect(ids(messagesOpen(rows, open))).toContain("i-0");
});

test("a mixed burst reads as each kind's count", () => {
  const rows = steered([notification(0), peer(0), inbox(0), notification(1)]);
  const { open } = opened(rows);
  const line = open.find((r) => r.backgroundRun)!;
  expect(line.backgroundRun).toMatchObject({ notifications: 2, messages: 3 });
  expect(label(line)).toContain("2 task notifications, 3 messages from agents");
});

test("quiet Report-from lines after the answer fold into the Worked for and group", () => {
  const rows = steered([report(0), report(1)]);
  const { closed, open } = opened(rows);
  expect(ids(closed).filter((id) => id.startsWith("backgroundTurn-r"))).toEqual([]);
  const line = open.find((r) => r.backgroundRun)!;
  expect(line.backgroundRun).toMatchObject({ reports: 2 });
  expect(label(line)).toContain("2 subagent reports");
});

test("a Report-from turn's work folds under the Worked for its report set going", () => {
  const rows = steered([
    report(0, false),
    row("t-2", "activity", 492, {
      inBackground: "r0",
      items: [{ kind: "tool", text: "", tool: { id: "c2", title: "git log", kind: "execute", status: "completed" } }],
    }),
    row("a-2", "assistant", 495, { text: "helper-0 landed its lane.", inBackground: "r0" }),
  ]);
  const closed = view(rows);
  const fold = closed.find((r) => r.id === `${WORKED}-backgroundTurn-r0`);
  expect(fold).toBeDefined();
  expect(ids(closed)).not.toContain("backgroundTurn-r0");
  expect(ids(closed)).not.toContain("t-2");
  expect(ids(closed).indexOf(fold!.id)).toBeLessThan(ids(closed).indexOf("a-2"));
  const open = view(rows, new Set([fold!.id]));
  expect(ids(open).indexOf("t-2")).toBeGreaterThan(ids(open).indexOf(fold!.id));
});

test("task notifications that set a turn going start its Worked for", () => {
  const rows = steered([
    notification(0),
    notification(1),
    row("a-2", "assistant", 420, { text: "Both lanes are done." }),
    row("sum-2", "turnSummary", 430, { status: "completed", toolCount: 0 }),
  ]);
  const closed = view(rows);
  expect(ids(closed).filter((id) => id.startsWith("n-"))).toEqual([]);
  const fold = closed.find((r) => r.id === `${WORKED}-n-0`);
  expect(fold).toBeDefined();
  expect(ids(closed).indexOf(fold!.id)).toBeLessThan(ids(closed).indexOf("a-2"));
  expect(ids(closed).indexOf("sum")).toBeLessThan(ids(closed).indexOf(fold!.id));
});

test("the person's steer is a fixed point: never folded or moved, whatever its text", () => {
  const own = row("s-2", "user", 402, { text: "Report from helper: I checked it myself", ...steerIn });
  const rows = steered([notification(0), own, notification(1)]);
  const shown = ids(view(rows));
  expect(shown).toContain("s-1");
  expect(shown).toContain("s-2");
  expect(shown.indexOf("u-0")).toBeLessThan(shown.indexOf("s-1"));
  expect(shown.indexOf("s-1")).toBeLessThan(shown.indexOf("s-2"));
  expect(harnessWork(own)).toBeUndefined();
});

test("a person's message, a tool's fire and a failed subagent's end are no harness work", () => {
  expect(harnessWork(peer(0, { fromPerson: true }))).toBeUndefined();
  expect(harnessWork(peer(1, { notice: { severity: "fire" } }))).toBeUndefined();
  const failed = row("subagentDone:f", "subagentDone", 500, { subagents: [{ id: "f", state: "failed" }] });
  expect(harnessWork(failed)).toBeUndefined();
  const shown = ids(view(steered([notification(0), failed, notification(1)])));
  expect(shown).toContain("subagentDone:f");
});

test("a surge hold stays the composer hat's: a held inbox event is its snapshot, never a transcript row", () => {
  expect(surgeOfEvent("inbox", { surgeHeld: true, surge: { held: 4, needYou: 1 } }, 9)).toEqual({
    held: 4,
    needYou: 1,
    seq: 9,
  });
  const shown = view(steered([notification(0), notification(1)]));
  expect(shown.some((r) => r.kind.toLowerCase().includes("surge"))).toBe(false);
});

test("the line's words for each mix", () => {
  const t = translate;
  const base = { finished: 0, stopped: 0, failed: 0, scheduled: 0, other: 0, commands: 0, rows: [] };
  expect(backgroundRunLabel(t, { ...base, notifications: 4 })).toBe("4 task notifications");
  expect(backgroundRunLabel(t, { ...base, notifications: 1, messages: 1 })).toBe(
    "1 task notification, 1 message from an agent",
  );
  expect(backgroundRunLabel(t, { ...base, finished: 2, failed: 1, commands: 3, reports: 2 })).toBe(
    "2 subagent reports, 3 background commands, 1 failed",
  );
});
