import { describe, expect, test } from "bun:test";
import { createAcpmuxDebug, type DebugChatHost } from "./debug";
import { debugAnswer, debugChangesRow } from "./debugActions";
import type { AcpmuxPermission, AcpmuxRow, AcpmuxSnapshot } from "./model";
import type { PermissionGroup } from "./permissions/protocol";

const permission = (permissionId: string, fields: Partial<AcpmuxPermission> = {}): AcpmuxRow => ({
  id: `p-${permissionId}`,
  version: 1,
  at: 0,
  kind: "permission",
  text: "",
  permission: {
    permissionId,
    pending: true,
    options: [
      { id: "deny", name: "Deny", allow: false },
      { id: "once", name: "Allow once", allow: true },
    ],
    ...fields,
  },
});
const group = (groupId: string, decisions: PermissionGroup["decisions"] = ["allow_once", "deny"]): PermissionGroup => ({
  groupId,
  sessionId: "s",
  turnId: null,
  revision: 3,
  state: "pending",
  items: [],
  decisions,
  decision: null,
});
const snapshot = (rows: AcpmuxRow[], groups: PermissionGroup[] = []) =>
  ({
    rows,
    permissionGroups: groups.length
      ? { supported: true, ready: true, groups, chatAllowance: false, loading: false, busy: false }
      : undefined,
  }) as Pick<AcpmuxSnapshot, "rows" | "permissionGroups">;
const edit = (id: string, path?: string): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind: "activity",
  text: "",
  items: [
    {
      kind: "tool",
      text: "Edit",
      tool: { id, title: "Edit", kind: "edit", status: "completed", diffs: path ? [{ path, newText: "x\n" }] : [] },
    },
  ],
});

describe("debug answer_permission", () => {
  test("the newest pending request, with its first allowing or denying option", () => {
    const rows = [permission("a"), permission("b"), permission("c", { pending: false })];
    expect(debugAnswer(snapshot(rows), {})).toEqual({ kind: "permission", permissionId: "b", optionId: "once" });
    expect(debugAnswer(snapshot(rows), { decision: "deny" })).toEqual({
      kind: "permission",
      permissionId: "b",
      optionId: "deny",
    });
    expect(debugAnswer(snapshot(rows), { permission_id: "a", option_id: "deny" })).toMatchObject({ permissionId: "a" });
  });

  test("errors name what is pending", () => {
    expect(debugAnswer(snapshot([permission("a")]), { permission_id: "z" })).toEqual({
      error: "no pending permission z",
      pending: ["a"],
    });
    expect(debugAnswer(snapshot([]), {})).toEqual({ error: "no pending permission", pending: [] });
    expect(debugAnswer(snapshot([permission("a")]), { option_id: "always" })).toMatchObject({
      error: "permission a has no option always",
    });
  });

  test("a group takes its own decisions; allow is allow_once", () => {
    const state = snapshot([], [group("g1"), group("g2", ["deny"])]);
    expect(debugAnswer(state, { group_id: "g1" })).toEqual({
      kind: "group",
      groupId: "g1",
      revision: 3,
      decision: "allow_once",
    });
    expect(debugAnswer(state, {})).toMatchObject({ error: "the group offers deny, not allow_once" });
    expect(debugAnswer(state, { decision: "deny" })).toMatchObject({ groupId: "g2", decision: "deny" });
  });
});

describe("debug open_changes", () => {
  test("the newest turn that changed files, or the row asked for", () => {
    const rows = [edit("one", "a.ts"), edit("two", "b.ts"), edit("none")];
    expect(debugChangesRow(rows)?.id).toBe("two");
    expect(debugChangesRow(rows, "one")?.id).toBe("one");
    expect(debugChangesRow([edit("none")])).toBeUndefined();
  });
});

describe("debug chat actions", () => {
  const host = (overrides: Partial<DebugChatHost> = {}) => {
    const calls: unknown[][] = [];
    const chat: DebugChatHost = {
      snapshot: () => ({ ...snapshot([permission("a")]), sessionId: "s1", sessions: [] }) as unknown as AcpmuxSnapshot,
      send: async (text) => calls.push(["send", text]),
      select: (id) => calls.push(["select", id]),
      answer: async (id, option) => calls.push(["answer", id, option]),
      respondGroup: async (id, revision, decision) => calls.push(["group", id, revision, decision]),
      openChanges: (row, path) => calls.push(["changes", row, path]),
      ...overrides,
    };
    return { calls, debug: createAcpmuxDebug({ replaceRows: () => {}, rowCount: () => 0, chat }) };
  };

  test("send_prompt goes through the host and reports a failure to connect", async () => {
    const { calls, debug } = host();
    expect(await debug.sendPrompt("run the tests")).toEqual({ sent: true, session: "s1" });
    expect(calls).toEqual([["send", "run the tests"]]);
    expect(await debug.sendPrompt("  ")).toEqual({ error: "empty prompt" });
    const offline = host({
      send: async () => {
        throw new Error("acpmux is not connected");
      },
    });
    expect(await offline.debug.sendPrompt("hi")).toEqual({ error: "acpmux is not connected" });
  });

  test("answer_permission answers through the card's path", async () => {
    const { calls, debug } = host();
    expect(await debug.answerPermission()).toMatchObject({ answered: { permissionId: "a", optionId: "once" } });
    expect(calls).toEqual([["answer", "a", "once"]]);
  });

  test("a page without a chat says so", async () => {
    const debug = createAcpmuxDebug({ replaceRows: () => {}, rowCount: () => 0 });
    expect(await debug.sendPrompt("x")).toEqual({ error: "this page has no chat" });
    expect(await debug.openChanges()).toEqual({ error: "this page has no chat" });
  });
});
