// A daemon task (`_acpmux/bg/start`, which a Claude `run_in_background` Bash call becomes through
// bg_hook) is a process-registry row of origin `daemon` (acpmux `hub/bg_registry.rs`). The
// hat reads it as a running command with a process id, so it shows with no turn running, once.
import { expect, test } from "bun:test";
import { backgroundCommands, processesOf } from "../src/agent-session/acpmux/session-info/processes";
import { trayItems } from "../src/agent-session/acpmux/subagents/runningTray";

const row = {
  id: "chat/bg-1234",
  sessionId: "chat",
  toolCallId: "bg-1234",
  taskId: "bg-1234",
  harness: "claude",
  command: "cargo test -p acpmux",
  description: "run the tests",
  cwd: "/tmp",
  startedAt: 100,
  endedAt: null,
  state: "running",
  exitCode: null,
  signal: null,
  reason: null,
  detail: null,
  origin: "daemon",
  outputBytes: null,
};

test("a daemon task's row is one running command in the hat, with no turn running", () => {
  const processes = processesOf({ processes: [row] }, "chat");
  expect(processes.map((p) => p.id)).toEqual(["chat/bg-1234"]);
  // The rewritten call ran in the foreground: the transcript holds no task of its own, and a
  // transcript task still marked running is dropped once the registry is listed.
  const phantom = { id: "toolu_1", command: "cargo test -p acpmux", state: "running" as const };
  const commands = backgroundCommands(processes, [phantom], true);
  expect(commands.map((c) => [c.id, c.state, c.processId, c.description])).toEqual([
    ["chat/bg-1234", "running", "chat/bg-1234", "run the tests"],
  ]);
  const items = trayItems([], commands, [], false);
  expect(items.map((item) => item.id)).toEqual(["chat/bg-1234"]);
  const ended = processesOf({ processes: [{ ...row, state: "failed", endedAt: 200, exitCode: 3 }] }, "chat");
  expect(trayItems([], backgroundCommands(ended, [], true), [], false)).toEqual([]);
});
