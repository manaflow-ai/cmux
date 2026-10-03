import { describe, expect, test } from "bun:test";
import {
  answerPermission,
  automationState,
  openChanges,
  selectSession,
  sendPrompt,
  setModel,
  models,
  type AutomationHost,
} from "./automation";
import type { AcpmuxSnapshot } from "./model";

function snapshot(overrides: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [{ sessionId: "s1", title: "First", harness: "claude" }],
    connection: "open",
    sessionId: "s1",
    isWorking: false,
    queue: [],
    catalog: [],
    canLoadOlder: false,
    ...overrides,
  };
}

function host(current: AcpmuxSnapshot) {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const selected: string[] = [];
  const opened: string[] = [];
  const fake: AutomationHost = {
    snapshot: () => current,
    call: async (method, params) => {
      calls.push([method, params]);
    },
    selectSession: (id) => selected.push(id),
    openDiff: (rowId) => opened.push(rowId),
    diff: () => ({ open: opened.length > 0, paths: [] }),
  };
  return { fake, calls, selected, opened };
}

const editRow = {
  id: "a1",
  version: 1,
  at: 0,
  kind: "activity",
  items: [
    {
      kind: "tool",
      text: "",
      tool: {
        id: "t1",
        title: "Edit",
        kind: "edit",
        status: "completed",
        diffs: [{ path: "/repo/a.txt", oldText: "a\n", newText: "b\n" }],
      },
    },
  ],
};

describe("agent pane automation", () => {
  test("sendPrompt runs the composer's chat.send action and refuses an empty prompt", async () => {
    const { fake, calls } = host(snapshot());
    expect(await sendPrompt(fake, "  ")).toEqual({ error: "empty prompt" });
    expect(await sendPrompt(fake, "hello")).toEqual({ sent: true, turnEnded: true, sessionId: "s1" });
    expect(calls).toEqual([["chat.send", { text: "hello" }]]);
  });

  test("sendPrompt returns while the turn runs, and reports a send that fails at once", async () => {
    const running: AutomationHost = { ...host(snapshot()).fake, call: () => new Promise(() => {}) };
    expect(await sendPrompt(running, "long", 10)).toEqual({ sent: true, turnEnded: false, sessionId: "s1" });
    const failing: AutomationHost = {
      ...host(snapshot()).fake,
      call: () => Promise.reject(new Error("harness unavailable")),
    };
    expect(await sendPrompt(failing, "x", 10)).toEqual({ error: "harness unavailable" });
  });

  test("a single ask is answered with its first allowing option, or the named one", async () => {
    const permission = {
      permissionId: "p1",
      pending: true,
      options: [
        { id: "deny", name: "Deny", allow: false },
        { id: "once", name: "Allow once", allow: true },
      ],
    };
    const { fake, calls } = host(snapshot({ permission }));
    expect(await answerPermission(fake)).toEqual({ answered: "p1", optionId: "once" });
    expect(await answerPermission(fake, { allow: false })).toEqual({ answered: "p1", optionId: "deny" });
    expect(calls.map(([method, params]) => [method, params?.optionId])).toEqual([
      ["chat.permission", "once"],
      ["chat.permission", "deny"],
    ]);
  });

  test("a grouped ask is answered through the group with its revision", async () => {
    const permissionGroups = {
      supported: true,
      ready: true,
      chatAllowance: false,
      loading: false,
      busy: false,
      groups: [
        {
          groupId: "g1",
          sessionId: "s1",
          turnId: "t1",
          revision: 3,
          state: "pending" as const,
          items: [],
          decisions: ["allow_once" as const, "deny" as const],
          decision: null,
        },
      ],
    };
    const { fake, calls } = host(snapshot({ permissionGroups }));
    expect(await answerPermission(fake, { decision: "allow_chat" })).toMatchObject({
      error: "decision allow_chat not offered",
    });
    expect(await answerPermission(fake)).toEqual({ answered: "g1", decision: "allow_once" });
    expect(calls).toEqual([["chat.permission_group.respond", { groupId: "g1", revision: 3, decision: "allow_once" }]]);
  });

  test("nothing pending is an error, not a call", async () => {
    const { fake, calls } = host(snapshot());
    expect(await answerPermission(fake)).toEqual({ error: "no pending permission" });
    expect(calls).toEqual([]);
  });

  test("openChanges opens the latest turn that edited files", () => {
    const { fake, opened } = host(
      snapshot({ rows: [{ id: "u1", version: 1, at: 0, kind: "user", text: "go" }, editRow] }),
    );
    expect(openChanges(fake)).toEqual({ opened: "a1", files: ["/repo/a.txt"] });
    expect(opened).toEqual(["a1"]);
    expect(openChanges(host(snapshot()).fake)).toEqual({ error: "no turn with edited files" });
  });

  test("selectSession only selects a listed session", () => {
    const { fake, selected } = host(snapshot());
    expect(selectSession(fake, "nope")).toMatchObject({ error: 'no session "nope"' });
    expect(selectSession(fake, "s1")).toEqual({ selected: "s1" });
    expect(selected).toEqual(["s1"]);
  });

  test("the state names the last reply, the pending asks and the changed files", () => {
    const rows = [
      { id: "u1", version: 1, at: 0, kind: "user", text: "go" },
      editRow,
      { id: "r1", version: 2, at: 1, kind: "assistant", text: "done", streaming: false },
    ];
    const state = automationState(host(snapshot({ rows })).fake);
    expect(state.lastAssistant).toEqual({ text: "done", streaming: false });
    expect(state.changedFiles).toEqual(["/repo/a.txt"]);
    expect(state.permission).toBeNull();
    expect(state.sessions).toEqual([{ sessionId: "s1", title: "First", harness: "claude", status: null }]);
  });

  test("setModel switches through chat.model, then chat.effort, and refuses a model the harness does not offer", async () => {
    const current = snapshot({
      summary: {
        sessionId: "s1",
        harness: "codex",
        model: "sol",
        configOptions: [{ id: "reasoning_effort", options: [{ value: "low" }, { value: "high" }] }],
      },
      catalog: [{ id: "codex", name: "Codex", models: [{ id: "sol", name: "Sol" }, { id: "luna" }] }],
    });
    const { fake, calls } = host(current);
    expect(await setModel(fake, "nope")).toMatchObject({
      error: 'model "nope" is not offered',
      models: ["sol", "luna"],
    });
    expect(await setModel(fake, "luna", "high")).toEqual({ model: "luna", effort: "high" });
    expect(calls).toEqual([
      ["chat.model", { modelId: "luna" }],
      ["chat.effort", { configId: "reasoning_effort", value: "high" }],
    ]);
    expect(models(fake)).toEqual({
      harness: "codex",
      current: "sol",
      models: [
        { id: "sol", name: "Sol" },
        { id: "luna", name: null },
      ],
    });
  });
});
