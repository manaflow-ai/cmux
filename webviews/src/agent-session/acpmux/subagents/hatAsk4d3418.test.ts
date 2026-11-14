// l10n-allow-file: test fixture commands and names, not shipped UI.
// The composer hat, on Leo's 2026-11-12 ask: failed lines leave it, its rim drags, and its lines cut
// at the row's edge instead of 40 characters in.
import { expect, test } from "bun:test";
import { endedInFailure, type TrayItem } from "./runningTray";
import { toolDetail } from "./trayDetail";
import { clampHatHeight, HAT_MIN_HEIGHT, hatDrag } from "./trayResize";
import type { Subagent } from "./subagentFold";
import type { BackgroundCommand } from "../session-info/processes";
import type { StartedSession } from "../started/startedSessions";

const t = (key: string, values?: Record<string, unknown>) =>
  key === "tools.runningCommand" ? `Running ${String(values?.command)}` : key;

test("a command line keeps its whole step: the row's CSS ellipsis cuts it, not a 40-character cap", () => {
  const command = "gh run watch 19283746 --repo acme/app --exit-status --interval 30 --compact";
  const detail = toolDetail(t as never, command, true);
  expect(detail).toBe(`Running ${command}`);
  expect(detail?.includes("…")).toBe(false);
});

const agent = (state: string): TrayItem => ({
  kind: "agent",
  id: state,
  depth: 0,
  agent: { id: state, state, parent: null, name: "Reviewer", startedAt: 1 } as unknown as Subagent,
});
const command = (state: string): TrayItem => ({
  kind: "command",
  id: state,
  command: { id: state, state, command: "make test" } as unknown as BackgroundCommand,
});
const session = (state: string): TrayItem => ({
  kind: "session",
  id: state,
  session: { sessionId: state, state, subsession: true } as unknown as StartedSession,
});

test("what failed leaves the hat; what completed or was stopped stays for its grace", () => {
  expect(endedInFailure(agent("failed"))).toBe(true);
  expect(endedInFailure(agent("errored"))).toBe(true);
  expect(endedInFailure(command("failed"))).toBe(true);
  expect(endedInFailure(session("failed"))).toBe(true);
  for (const kept of [agent("completed"), agent("cancelled"), agent("disconnected"), agent("running")])
    expect(endedInFailure(kept)).toBe(false);
  expect(endedInFailure(command("completed"))).toBe(false);
  expect(endedInFailure(command("killed"))).toBe(false);
  expect(endedInFailure(session("idle"))).toBe(false);
});

test("the rim's drag sizes the list between one line and 70% of the window", () => {
  expect(clampHatHeight(5, 1000)).toBe(HAT_MIN_HEIGHT);
  expect(clampHatHeight(300.4, 1000)).toBe(300);
  expect(clampHatHeight(5000, 1000)).toBe(700);
  // Open at 140px: up 60px is 200px, down 60px is 80px, down past its last line folds it.
  expect(hatDrag(140, 60, 1000)).toEqual({ kind: "size", height: 200 });
  expect(hatDrag(140, -60, 1000)).toEqual({ kind: "size", height: 80 });
  expect(hatDrag(140, -135, 1000)).toEqual({ kind: "fold" });
  // A click or a small wobble does nothing, open or folded; a real drag up opens it to that height.
  expect(hatDrag(140, 3, 1000)).toEqual({ kind: "rest" });
  expect(hatDrag(140, -3, 1000)).toEqual({ kind: "rest" });
  expect(hatDrag(0, 4, 1000)).toEqual({ kind: "rest" });
  expect(hatDrag(0, -20, 1000)).toEqual({ kind: "rest" });
  expect(hatDrag(0, 120, 1000)).toEqual({ kind: "size", height: 120 });
});
