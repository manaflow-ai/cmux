// l10n-allow-file: test fixture folders, branches and agent names, not shipped UI.
// What Session Info reads for a subagent (session-info/subagentScope.ts; Leo, 2026-10-21: "subagent
// should have its own instance of it like it might have different env worktree context bg tasks
// outputs and diffs etc"): the worktree Claude's Agent call reports, the subagent's own folder and
// branch, never the chat's, and only its own processes, background shells and nested subagents.
import { expect, test } from "bun:test";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import {
  descendants,
  subagentChangesFolder,
  subagentProcesses,
  subagentSummary,
  withChatEnds,
  worktreeOfRows,
} from "../src/agent-session/acpmux/session-info/subagentScope";
import { SubagentFold, worktreeIn, type Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import { activity, tool } from "../src/gallery/fixtures/acpmux";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const CHAT: Summary = {
  sessionId: "chat-1",
  cwd: "/Users/you/src/atlas-web",
  branch: "feat/retries",
  usage: { used: 90_000, size: 200_000 },
  mcpServers: [{ name: "github", status: "connected" }],
};
const TREE = "/Users/you/src/atlas-web/.claude/worktrees/agent-a3f9c2";
const agent = (fields: Partial<Subagent> = {}): Subagent => ({
  id: "chat-1/toolu_1",
  parent: null,
  name: "Fix the timeouts",
  state: "running",
  startedAt: 1,
  ...fields,
});

let seq = 0;
function feed(fold: SubagentFold, update: any, acpmux: Record<string, unknown> = {}) {
  seq += 1;
  return fold.reduce({ seq, at: seq * 1000, msg: { params: { update, _meta: { acpmux } } } }, update);
}

test("a Claude Agent call that asks for a worktree marks its subagent, and its result names the worktree", () => {
  const fold = new SubagentFold();
  feed(
    fold,
    { sessionUpdate: "subagent_spawned" },
    { subagents: [{ id: "chat-1/toolu_1", parent: null, name: "Fix the timeouts", toolCallId: "toolu_1" }] },
  );
  feed(fold, {
    sessionUpdate: "tool_call",
    toolCallId: "toolu_1",
    title: "Agent",
    rawInput: { description: "Fix the timeouts", prompt: "…", isolation: "worktree" },
  });
  expect(fold.all()[0]).toMatchObject({ isolated: true });
  expect(fold.all()[0]!.worktree).toBeUndefined();
  feed(fold, {
    sessionUpdate: "tool_call_update",
    toolCallId: "toolu_1",
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "text",
          text: `Done.\nworktreePath: ${TREE}\nworktreeBranch: worktree-agent-a3f9c2\nagentId: a3f9c2 (internal ID)`,
        },
      },
    ],
  });
  const [found] = fold.all();
  expect(found).toMatchObject({
    isolated: true,
    agentId: "a3f9c2",
    worktree: { path: TREE, branch: "worktree-agent-a3f9c2" },
  });
});

test("worktreeIn reads Claude's worktree lines, and nothing from other text", () => {
  expect(worktreeIn(`x\nworktreePath: ${TREE}\nworktreeBranch: wt-1`)).toEqual({ path: TREE, branch: "wt-1" });
  expect(worktreeIn(`worktreePath: ${TREE}`)).toEqual({ path: TREE });
  expect(worktreeIn("the worktreePath: field is relative")).toBeUndefined();
  expect(worktreeIn("worktreePath: relative/path")).toBeUndefined();
});

const treeRows: AcpmuxRow[] = [
  activity(
    [
      tool("Edit fetch.ts", "edit", "completed", {
        diffs: [{ path: `${TREE}/src/net/fetch.ts`, oldText: "a\n", newText: "b\n" }],
      }),
      tool("Run tests", "execute", "in_progress", {
        command: "bun test --watch",
        inputSummary: JSON.stringify({ command: "bun test --watch", run_in_background: true }),
      }),
    ],
    2,
  ),
];

test("a subagent in a worktree gets its own folder and branch, never the chat's, and no usage or connectors", () => {
  const own = subagentSummary(CHAT, agent({ worktree: { path: TREE, branch: "worktree-agent-a3f9c2" } }), []);
  expect(own).toMatchObject({ cwd: TREE, worktree: TREE, branch: "worktree-agent-a3f9c2" });
  expect(own?.usage).toBeUndefined();
  expect(own?.mcpServers).toBeUndefined();
  // Before its result: the worktree its tool calls work in, and no branch (the chat's is not its).
  const early = subagentSummary(CHAT, agent({ isolated: true }), treeRows);
  expect(early).toMatchObject({ cwd: TREE, worktree: TREE });
  expect(early?.branch).toBeUndefined();
  expect(worktreeOfRows(treeRows)).toBe(TREE);
  // Asked for one, not yet in it: no branch either.
  expect(subagentSummary(CHAT, agent({ isolated: true }), [])?.branch).toBeUndefined();
  // In the chat's own checkout: the chat's folder and branch.
  expect(subagentSummary(CHAT, agent(), [])).toMatchObject({ cwd: CHAT.cwd, branch: CHAT.branch });
  expect(
    subagentChangesFolder(CHAT, { agent: agent({ isolated: true }), rows: treeRows, parent: "chat", agents: [] }),
  ).toBe(TREE);
  expect(subagentChangesFolder(CHAT, { agent: agent(), rows: [], parent: "chat", agents: [] })).toBe(CHAT.cwd);
});

test("only the processes the subagent's own calls started, and its nested subagents", () => {
  const callId = treeRows[0]!.items![1]!.tool!.id;
  const processes = [
    { id: "s/1", toolCallId: callId, command: "bun test --watch", startedAt: 1, state: "running" },
    { id: "s/2", toolCallId: "chat-call", command: "bun run dev", startedAt: 1, state: "running" },
    { id: "s/3", command: "tail -f log", startedAt: 1, state: "running" },
  ];
  expect(subagentProcesses(processes, treeRows).map((process) => process.id)).toEqual(["s/1"]);
  const all = [
    agent({ id: "a" }),
    agent({ id: "b", parent: "a" }),
    agent({ id: "c", parent: "b" }),
    agent({ id: "d" }),
  ];
  expect(descendants(all, "a").map((found) => found.id)).toEqual(["b", "c"]);
  expect(descendants(all, "d")).toEqual([]);
});

test("a subagent's background shell ends where the chat's rows note it", () => {
  const callId = treeRows[0]!.items![1]!.tool!.id;
  const tasks = sessionSummary(treeRows).backgroundTasks;
  expect(tasks.map((task) => task.state)).toEqual(["running"]);
  const ended = withChatEnds(tasks, [
    {
      id: "bgtask-9",
      version: 1,
      at: 9,
      kind: "backgroundTask",
      backgroundTask: { toolCallId: callId, command: "bun test --watch", state: "completed" },
    },
  ]);
  expect(ended.map((task) => task.state)).toEqual(["completed"]);
  expect(withChatEnds(tasks, [])).toBe(tasks);
});

test("a nested subagent's Agent call, its parent's update, still gives it its worktree", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Lead" }] });
  feed(
    fold,
    { sessionUpdate: "subagent_spawned" },
    { subagents: [{ id: "b", parent: "a", name: "Worker", toolCallId: "toolu_9" }] },
  );
  feed(
    fold,
    { sessionUpdate: "tool_call", toolCallId: "toolu_9", title: "Agent", rawInput: { isolation: "worktree" } },
    { subagent: "a" },
  );
  feed(
    fold,
    {
      sessionUpdate: "tool_call_update",
      toolCallId: "toolu_9",
      content: [{ type: "content", content: { type: "text", text: `worktreePath: ${TREE}\nworktreeBranch: wt-b` } }],
    },
    { subagent: "a" },
  );
  expect(fold.all().find((found) => found.id === "b")).toMatchObject({
    isolated: true,
    worktree: { path: TREE, branch: "wt-b" },
  });
});

test("a worktree path with a space, and a chat already in the worktree its subagent works in", () => {
  expect(worktreeIn("worktreePath: /Users/you/My Repo/.claude/worktrees/x  \nworktreeBranch: wt-x")).toEqual({
    path: "/Users/you/My Repo/.claude/worktrees/x",
    branch: "wt-x",
  });
  // The chat runs in that worktree: the subagent shares its checkout, folder and branch.
  const inTree = { ...CHAT, cwd: TREE, worktree: TREE, branch: "worktree-agent-a3f9c2" };
  expect(subagentSummary(inTree, agent(), treeRows)).toMatchObject({
    cwd: TREE,
    worktree: TREE,
    branch: "worktree-agent-a3f9c2",
  });
  // A folder it was given outside its worktree does not hide the worktree.
  expect(subagentSummary(CHAT, agent({ cwd: "/tmp/elsewhere", worktree: { path: TREE } }), [])?.cwd).toBe(TREE);
  expect(subagentSummary(CHAT, agent({ cwd: `${TREE}/web`, worktree: { path: TREE } }), [])?.cwd).toBe(`${TREE}/web`);
});
