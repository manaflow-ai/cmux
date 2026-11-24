// Turns that drew nothing but their closed "Worked for" join into one line (turns.ts `joinBareWorked`).
// Austin's chat, 2026-11-17: five lines "Worked for 37s", "Worked for 3s", "Worked for 1m", ... stacked
// with nothing between them, one per wake the agent answered with tools alone (Leo: "we sometimes have
// weird ui like this").
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { received } from "../incomingFixture";
import { WORKED, foldCovers, toggleTurnFold, turnView } from "./turns";

const sent = (n: number) => ({
  id: `msg_${n}`,
  thread: `msg_${n}`,
  sender: "acp:0190a000-0000-7000-8000-0000000000f1",
  name: "grid-fix",
  body: `Status ${n}: still running.`,
});

// Three calls each: a turn folds under "Worked for" only with three work rows or five seconds
// (workedForSmallTurns.test.tsx), and these wakes are about turns that do.
const run = (id: string, at: number): AcpmuxRow =>
  ({
    id,
    version: 1,
    at,
    kind: "activity",
    toolCount: 3,
    items: [0, 1, 2].map((call) => ({
      kind: "tool",
      text: "ls",
      tool: { id: `${id}-call${call}`, title: "ls", kind: "execute", status: "completed", command: "ls" },
    })),
  }) as AcpmuxRow;

/// A wake the agent answered with one command and no words: a hidden prompt, or another agent's message.
function wake(n: number, at: number, durationMs: number, message: boolean): AcpmuxRow[] {
  const prompt: AcpmuxRow = message
    ? received(`wake-${n}`, at, sent(n))
    : ({ id: `wake-${n}`, version: 1, at, kind: "user", text: "", incoming: { kind: "hidden" } } as AcpmuxRow);
  return [
    prompt,
    run(`run-${n}`, at + 500),
    {
      id: `sum-${n}`,
      version: 1,
      at: at + durationMs,
      kind: "turnSummary",
      status: "completed",
      durationMs,
      toolCount: 1,
    },
  ];
}

function chat(message: boolean): AcpmuxRow[] {
  return [
    { id: "ask", version: 1, at: 1_000, kind: "user", text: "Watch the build" },
    run("look", 1_500),
    { id: "reply", version: 1, at: 2_000, kind: "assistant", text: "Watching it." },
    { id: "sum-0", version: 1, at: 2_100, kind: "turnSummary", status: "completed", durationMs: 1_100, toolCount: 1 },
    ...wake(1, 10_000, 37_000, message),
    ...wake(2, 60_000, 3_000, message),
    ...wake(3, 70_000, 60_000, message),
  ];
}

const options = { now: 200_000, working: false };

for (const family of ["codex", "claude"]) {
  for (const message of [false, true]) {
    const kind = message ? "another agent's messages" : "hidden wakes";
    test(`${family}: reply-less turns after ${kind} draw one Worked for, not one each`, () => {
      const shown = turnView(chat(message), new Set(), { ...options, agentFamily: family });
      const lines = shown.filter((row) => row.kind === WORKED && row.workedRun);
      expect(lines).toHaveLength(1);
      expect(lines[0]!.durationMs).toBe(100_000);
      // No two "Worked for" lines touch: something the person can read always sits between them.
      shown.forEach((row, at) => {
        if (at > 0 && row.kind === WORKED) expect(shown[at - 1]!.kind).not.toBe(WORKED);
      });
    });

    test(`${family}: opening the joined line after ${kind} opens every turn it stands for`, () => {
      const rows = chat(message);
      const closed = turnView(rows, new Set(), { ...options, agentFamily: family });
      const line = closed.find((row) => row.kind === WORKED && row.workedRun)!;
      const opened = toggleTurnFold(rows, new Set(), line.id, foldCovers(line));
      const shown = turnView(rows, opened, { ...options, agentFamily: family });
      for (const n of [1, 2, 3]) expect(shown.some((row) => row.id === `run-${n}`)).toBe(true);
      // Closed again from its first line, every member folds back into the one line.
      const first = shown.find((row) => row.id === line.id)!;
      const again = toggleTurnFold(rows, opened, first.id, foldCovers(first));
      expect([...again].filter((key) => !key.startsWith("closed")).length).toBe(0);
    });
  }
}

test("a reply between two reply-less turns keeps each its own Worked for", () => {
  const rows = [
    ...chat(false).slice(0, 4),
    ...wake(1, 10_000, 37_000, false),
    { id: "said", version: 1, at: 50_000, kind: "user", text: "how is it going" } as AcpmuxRow,
    { id: "answer", version: 1, at: 51_000, kind: "assistant", text: "Still building." } as AcpmuxRow,
    {
      id: "sum-said",
      version: 1,
      at: 52_000,
      kind: "turnSummary",
      status: "completed",
      durationMs: 2_000,
    } as AcpmuxRow,
    ...wake(2, 60_000, 3_000, false),
  ];
  const shown = turnView(rows, new Set(), { ...options, agentFamily: "codex" });
  expect(shown.filter((row) => row.kind === WORKED && row.workedRun?.ids.length === 1)).toHaveLength(2);
});
