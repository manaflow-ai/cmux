// l10n-allow-file: test fixture subagent names and replies, not shipped UI.
// A background subagent's line never reads as its tool's bare name (Leo, 2026-11-05, on a tray of
// subagents each reading "Bash": "these are all bash? How are they all bash? Aren't they
// sub-agents?"). Claude's progress names a background subagent's last tool so when it has no
// summary; its own last words lead that, and a bare shell name reads "Running a command".
import { expect, test } from "bun:test";
import { setPaneLanguage, translate } from "../src/agent-session/acpmux/i18n";
import { SubagentFold, type Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { latestLine, namedAction } from "../src/agent-session/acpmux/subagents/trayDetail";
import { AgentProgressStore } from "../src/agent-session/acpmux/subagents/agentProgressSource";

setPaneLanguage("en");
const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) =>
  translate(key, values, "en");

const agent = (fields: Partial<Subagent> = {}): Subagent => ({
  id: "a",
  parent: null,
  name: "Cloud dev loop",
  state: "running",
  startedAt: 1_000,
  ...fields,
});

test("a step known only by its tool's name gives way to what the agent last said", () => {
  expect(latestLine(t, agent({ action: "Bash", lastMessage: "Waiting on CI for #39120." }), false)).toBe(
    "Waiting on CI for #39120.",
  );
  expect(latestLine(t, agent({ action: "Read", lastMessage: "Reading the tray." }), false)).toBe("Reading the tray.");
});

test("with nothing said, a bare shell name reads as running a command, never Bash", () => {
  expect(latestLine(t, agent({ action: "Bash" }), false)).toBe("Running a command");
  expect(namedAction(t, "Bash")).toBe("Running a command");
  expect(namedAction(t, "exec_command")).toBe("Running a command");
  // A real step, or a summary, stays as it is.
  expect(namedAction(t, "Read warm-sources.json")).toBe("Read warm-sources.json");
  expect(namedAction(t, "ls", true)).toBe("ls");
  expect(latestLine(t, agent({ action: "Read warm-sources.json", lastMessage: "x" }), false)).toBe(
    "Read warm-sources.json",
  );
});

test("a subagent's call titled only Bash takes its command from the call's input", () => {
  const fold = new SubagentFold();
  let seq = 0;
  const feed = (update: any, acpmux: Record<string, unknown>) => {
    seq += 1;
    fold.reduce(
      { seq, at: seq * 1000, msg: { method: "session/update", params: { update, _meta: { acpmux } } } },
      update,
    );
  };
  feed({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Watch CI" }] });
  feed(
    {
      sessionUpdate: "tool_call",
      toolCallId: "t1",
      title: "Bash",
      kind: "execute",
      status: "in_progress",
      rawInput: { command: "glaeda-gh wait pr 39120" },
    },
    { subagent: "a" },
  );
  const watched = fold.all().find((one) => one.id === "a")!;
  expect(watched.action).toBe("glaeda-gh wait pr 39120");
  expect(watched.actionShell).toBe(true);
  expect(latestLine(t, watched, false)).toContain("glaeda-gh");
});

test("a shell call announced before its input (Bash, kind execute) is still a bare name", () => {
  const announced = agent({ action: "Bash", actionShell: true, lastMessage: "Waiting on CI for #39120." });
  expect(latestLine(t, announced, false)).toBe("Waiting on CI for #39120.");
  expect(latestLine(t, { ...announced, lastMessage: undefined }, false)).toBe("Running a command");
  expect(namedAction(t, "Bash", true)).toBe("Running a command");
});

test("a new last message alone draws the line again", () => {
  const store = new AgentProgressStore();
  store.updateAgent(agent({ action: "Bash", lastMessage: "Started the build." }));
  const before = store.structureVersion;
  store.updateAgent(agent({ action: "Bash", lastMessage: "The build is green." }));
  expect(store.structureVersion).toBeGreaterThan(before);
});
