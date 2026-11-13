// l10n-allow-file: test fixture text, not shipped UI.
// A steer the agent has not read yet names the step it waits behind, in the live line's own words, and
// says nothing once the agent read it (Leo, 2026-11-12: "They have tons of helpers and they're not
// really responding to my messages. I'm not sure if they're reading them at all.").
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnView, turnViewFrom } from "./turns";

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});
const call = (id: string, at: number, tool: NonNullable<AcpmuxRow["items"]>[number]["tool"]) =>
  row(id, "activity", at, { items: [{ kind: "tool", text: tool!.title, tool }] });
const steer = (extra: Partial<AcpmuxRow> = {}) =>
  row("steer", "user", 20_000, { text: "Are you reading these?", steer: "waiting", steerPromptId: "p-2", ...extra });
const live = (rows: AcpmuxRow[], trayAgents = 0) =>
  turnView([row("prompt", "user", 0, { text: "Land the three fixes" }), ...rows], new Set(), {
    now: 60_000,
    working: true,
    agentFamily: "claude",
    trayAgents,
  });
const steerIn = (rows: AcpmuxRow[]) => rows.find((r) => r.id === "steer");

test("a waiting steer names the running command it waits behind", () => {
  const rows = live([
    row("plan", "assistant", 1_000, { text: "Waiting on CI." }),
    call("wait", 10_000, {
      id: "t1",
      kind: "execute",
      title: "gh pr checks 42 --watch",
      command: "gh pr checks 42 --watch",
      status: "in_progress",
    }),
    // Sent while the command runs: drawn after it, where it went into the turn.
    steer({ at: 30_000 }),
  ]);
  expect(steerIn(rows)?.steerBehind).toEqual({ command: "gh pr checks 42 --watch" });
});

test("a waiting steer names the call it waits behind by the live line's words", () => {
  const rows = live([
    steer(),
    call("read", 10_000, { id: "t2", kind: "read", title: "Read turns.ts", status: "in_progress" }),
  ]);
  const behind = steerIn(rows)?.steerBehind;
  expect(behind?.call).toBeTruthy();
  expect(behind?.call).toBe(rows.at(-1)!.doing);
});

test("a waiting steer behind foreground subagents says how many", () => {
  const rows = live([row("plan", "assistant", 1_000, { text: "Three helpers are on it." }), steer()], 3);
  expect(steerIn(rows)?.steerBehind).toEqual({ agents: 3 });
});

test("a waiting steer between steps names no step", () => {
  const rows = live([row("plan", "assistant", 1_000, { text: "Looking." }), steer()]);
  expect(steerIn(rows)?.steerBehind).toEqual({});
});

test("a steer the agent read carries no mark", () => {
  const rows = live([
    steer({ steer: "landed" }),
    call("wait", 10_000, { id: "t1", kind: "execute", title: "sleep 9", command: "sleep 9", status: "in_progress" }),
  ]);
  expect(steerIn(rows)?.steerBehind).toBeUndefined();
});

test("another session's waiting message keeps its row, for the waiting card's group", () => {
  const incoming = row("msg", "user", 20_000, {
    text: "From the lane",
    steer: "waiting",
    steerPromptId: "p-3",
    incoming: { kind: "message", message: { name: "lane", text: "From the lane", raw: "From the lane" } },
  });
  const source = [
    row("prompt", "user", 0, { text: "Land the three fixes" }),
    call("wait", 10_000, { id: "t1", kind: "execute", title: "sleep 9", command: "sleep 9", status: "in_progress" }),
    incoming,
  ];
  const view = turnViewFrom(source, new Set(), { now: 60_000, working: true, agentFamily: "claude" });
  const all = [...view.rows, ...(view.pending ?? [])];
  for (const drawn of all.filter((r) => r.id === "msg")) expect(drawn).toBe(incoming);
});
