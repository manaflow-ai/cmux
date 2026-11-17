// l10n-allow-file: test fixtures, not shipped UI.
// While no list of a chat's whole process history shows, its page keeps every running process and
// only the newest ended ones (session-info/processes.ts `recentProcesses`, acpmux `recent`): a god chat
// ran 56,000 shells, and the page held all of them for a tray of a few (2026-11-16).
import { expect, test } from "bun:test";
import {
  mergeProcess,
  recentProcesses,
  type SessionInfoProcess,
} from "../src/agent-session/acpmux/session-info/processes";

const CHAT = "0190a000-0000-7000-8000-0000000000e5";
const row = (n: number, state = n % 1_000 === 3 ? "running" : "exited") =>
  ({ id: `${CHAT}/task-${n}`, sessionId: CHAT, command: `step ${n}`, state, startedAt: n }) as SessionInfoProcess;

test("a short list is kept as it is, the same array", () => {
  const processes = Array.from({ length: 40 }, (_, n) => row(n));
  expect(recentProcesses(processes, 100)).toBe(processes);
});

test("a long list keeps every running process, however old, and the newest ended, in order", () => {
  const processes = Array.from({ length: 5_000 }, (_, n) => row(n));
  const kept = recentProcesses(processes, 100);
  expect(kept.filter((p) => p.state === "running").map((p) => p.id)).toEqual(
    [3, 1_003, 2_003, 3_003, 4_003].map((n) => `${CHAT}/task-${n}`),
  );
  const ended = kept.filter((p) => p.state !== "running");
  expect(ended).toHaveLength(100);
  expect(ended[0]!.id).toBe(`${CHAT}/task-4900`);
  expect(kept.map((p) => p.startedAt)).toEqual([...kept.map((p) => p.startedAt)].sort((a, b) => a - b));
});

test("updates past the window stay bounded: the oldest ended one goes as a new one arrives", () => {
  let processes: readonly SessionInfoProcess[] = Array.from({ length: 100 }, (_, n) => row(n, "exited"));
  for (let n = 100; n < 2_000; n += 1)
    processes = recentProcesses(mergeProcess(processes, row(n, "exited"), CHAT), 100);
  expect(processes).toHaveLength(100);
  expect(processes[0]!.id).toBe(`${CHAT}/task-1900`);
});
