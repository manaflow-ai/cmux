// l10n-allow-file: test fixture subagent names and replies, not shipped UI.
// A bare shell name stays as the neutral tool title when no command has arrived (Leo, 2026-11-23:
// "running" doesn't need text). Claude's progress names a background subagent's last tool so when
// it has no summary; its own last words lead that.
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

test("with nothing said, a bare shell name says nothing: not Bash, not a running word (Leo, 2026-11-23)", () => {
  expect(latestLine(t, agent({ action: "Bash" }), false)).toBeUndefined();
  expect(namedAction(t, "Bash")).toBeUndefined();
  expect(namedAction(t, "exec_command")).toBeUndefined();
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
      rawInput: { command: "gh pr checks 39120 --required" },
    },
    { subagent: "a" },
  );
  const watched = fold.all().find((one) => one.id === "a")!;
  expect(watched.action).toBe("gh pr checks 39120 --required");
  expect(watched.actionShell).toBe(true);
  expect(latestLine(t, watched, false)).toContain("gh");
});

test("a shell call announced before its input (Bash, kind execute) is still a bare name", () => {
  const announced = agent({ action: "Bash", actionShell: true, lastMessage: "Waiting on CI for #39120." });
  expect(latestLine(t, announced, false)).toBe("Waiting on CI for #39120.");
  expect(latestLine(t, { ...announced, lastMessage: undefined }, false)).toBeUndefined();
  expect(namedAction(t, "Bash", true)).toBeUndefined();
});

test("a new last message alone draws the line again", () => {
  const store = new AgentProgressStore();
  store.updateAgent(agent({ action: "Bash", lastMessage: "Started the build." }));
  const before = store.structureVersion;
  store.updateAgent(agent({ action: "Bash", lastMessage: "The build is green." }));
  expect(store.structureVersion).toBeGreaterThan(before);
});

test("a Bash call whose command arrives in a later update without its title reads that command", () => {
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
    { sessionUpdate: "tool_call", toolCallId: "t1", title: "Bash", kind: "execute", status: "pending" },
    { subagent: "a" },
  );
  expect(
    latestLine(
      t,
      fold.all().find((one) => one.id === "a")!,
      false,
    ),
  ).toBeUndefined();
  feed(
    { sessionUpdate: "tool_call_update", toolCallId: "t1", rawInput: { command: "bun test test/tray.test.ts" } },
    { subagent: "a" },
  );
  const watched = fold.all().find((one) => one.id === "a")!;
  expect(watched.action).toBe("bun test test/tray.test.ts");
  expect(watched.actionShell).toBe(true);
  // A later update with a real title keeps that title.
  feed({ sessionUpdate: "tool_call", toolCallId: "t2", title: "Read tray.ts", status: "pending" }, { subagent: "a" });
  expect(fold.all().find((one) => one.id === "a")!.action).toBe("Read tray.ts");
});
