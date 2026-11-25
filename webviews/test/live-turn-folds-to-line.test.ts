// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
//
// #50987: a running turn drew every tool call and thought open under "Working for 8m 47s", dozens of
// rows the reader found overwhelming. The Codex app and chatgpt.com fold a running turn's steps into
// one live line with the latest step, which a click opens. A running turn now draws its replies and
// that one line under a closed "Working for"; the line's click opens the work under the key the
// turn's "Worked for" takes when it ends, so the end keeps what the reader chose, in the same place.
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { THINKING, WORKED, turnHeaderId, turnView } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 22, 9, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const call = (id: string, command: string, status: string): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: command, kind: "execute", status, command },
});

// The experiments a test sets stay its own.
beforeEach(() => {
  delete globalThis.cmuxExperiments;
});
afterEach(() => {
  delete globalThis.cmuxExperiments;
});

/// A running turn: a short note, a finished run, a reply, and a command still running.
const running: AcpmuxRow[] = [
  row("u1", "user", 0, { text: "Tidy the glass styles" }),
  row("a1", "activity", 2, {
    items: [call("c1", "rg glass", "completed"), call("c2", "cat glass.css", "completed")],
  }),
  row("m1", "assistant", 10, { text: "I'm checking the blur values next, then the borders." }),
  row("a2", "activity", 12, {
    items: [call("c3", "git diff", "completed"), call("c4", "bun test glass", "in_progress")],
  }),
];
const ended: AcpmuxRow[] = [
  ...running.slice(0, -1),
  row("a2", "activity", 12, {
    items: [call("c3", "git diff", "completed"), call("c4", "bun test glass", "completed")],
  }),
  row("m2", "assistant", 40, { text: "The glass styles are tidied, and the tests pass." }),
  row("s1", "turnSummary", 41, { status: "completed", durationMs: 41_000 }),
];

/// The turn's header: "Working for" while it runs, the same row as "Worked for" once it ended.
const runningHeader = (rows: readonly AcpmuxRow[]) =>
  rows.find((shown) => shown.kind === WORKED && shown.turnPhase === "running");
const calls = (rows: readonly AcpmuxRow[]) =>
  rows.flatMap((shown) => (shown.kind === "activity" ? (shown.items ?? []) : [])).map((item) => item.tool?.id);

test("a running turn draws its replies and one live line under a closed Working for", () => {
  const view = turnView(running, new Set(), { now: START + 30_000, working: true, agentFamily: "claude" });
  const header = runningHeader(view);
  expect(header).toBeDefined();
  expect(header!.foldOpen).toBe(false);
  // No finished call draws a row of its own; the reply stays in sight.
  expect(calls(view)).toEqual([]);
  expect(view.some((shown) => shown.id === "m1")).toBe(true);
  // The one live line, last, names the step running now.
  const line = view.at(-1)!;
  expect(line.kind).toBe(THINKING);
  expect(line.doing).toContain("Testing glass");
});

test("opening the Working for shows every call while the turn runs", () => {
  const closed = turnView(running, new Set(), { now: START + 30_000, working: true, agentFamily: "claude" });
  // The header toggles its own id, the key its "Worked for" opens with.
  const key = runningHeader(closed)!.id;
  expect(key).toBe(turnHeaderId("u1"));
  const view = turnView(running, new Set([key]), { now: START + 30_000, working: true, agentFamily: "claude" });
  expect(runningHeader(view)!.foldOpen).toBe(true);
  expect(calls(view)).toEqual(expect.arrayContaining(["c1", "c2", "c3"]));
});

test("the turn's end keeps the fold the reader left, where the Working for stood", () => {
  for (const open of [false, true]) {
    const folds = new Set(open ? [turnHeaderId("u1")] : []);
    const live = turnView(running, folds, { now: START + 30_000, working: true, agentFamily: "claude" });
    const done = turnView(ended, folds, { now: START + 60_000, working: false, agentFamily: "claude" });
    const header = live.findIndex((shown) => shown.kind === WORKED && shown.turnPhase === "running");
    const worked = done.findIndex((shown) => shown.kind === WORKED);
    expect(header).toBeGreaterThanOrEqual(0);
    expect(worked).toBe(header);
    expect(done[worked]!.id).toBe(live[header]!.id);
    expect(done[worked]!.turnPhase).not.toBe("running");
    expect(done[worked]!.foldOpen === true).toBe(open);
    // Closed, the work stays out of sight through the end, as it was while the turn ran.
    if (!open) expect(calls(done)).toEqual([]);
  }
});

test("the other arms still draw as they did", () => {
  globalThis.cmuxExperiments = { "live-turn-work": "open" };
  const view = turnView(running, new Set(), { now: START + 30_000, working: true, agentFamily: "claude" });
  expect(calls(view)).toEqual(expect.arrayContaining(["c1", "c2", "c3"]));
});
