import { describe, expect, test } from "bun:test";
import { createAcpmuxDebug, type DebugChatHost } from "./debug";
import { cardPermission, debugAnswer, debugChangesRow } from "./debugActions";
import type { AcpmuxPermission, AcpmuxRow, AcpmuxSnapshot } from "./model";
import type { PermissionGroup } from "./permissions/protocol";

// Agents often list the "always" options first; the card's y and n keys skip them.
const permission = (permissionId: string, fields: Partial<AcpmuxPermission> = {}): AcpmuxPermission => ({
  permissionId,
  pending: true,
  options: [
    { id: "allow_always", name: "Always allow", allow: true },
    { id: "reject_always", name: "Always reject", allow: false },
    { id: "allow_once", name: "Allow", allow: true },
    { id: "reject_once", name: "Reject", allow: false },
  ],
  ...fields,
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
const state = (single?: AcpmuxPermission, groups: PermissionGroup[] = []) =>
  ({
    permission: single,
    permissionGroups: groups.length
      ? { supported: true, ready: true, groups, chatAllowance: false, loading: false, busy: false }
      : undefined,
  }) as Pick<AcpmuxSnapshot, "permission" | "permissionGroups">;
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
  test("answers the card's request with the option its y or n key would pick, never an always option", () => {
    expect(debugAnswer(state(permission("a")), {})).toEqual({
      kind: "permission",
      permissionId: "a",
      optionId: "allow_once",
    });
    expect(debugAnswer(state(permission("a")), { decision: "deny" })).toMatchObject({ optionId: "reject_once" });
    expect(debugAnswer(state(permission("a")), { option_id: "allow_always" })).toMatchObject({
      optionId: "allow_always",
    });
  });

  test("the card's request is the snapshot's pending permission, unless the grouped panel answers it", () => {
    expect(cardPermission(state(permission("a")))?.permissionId).toBe("a");
    expect(cardPermission(state(permission("a", { pending: false })))).toBeUndefined();
    // Without group support the card still shows a request that carries a group id.
    expect(cardPermission(state(permission("a", { groupId: "g" })))?.permissionId).toBe("a");
    expect(cardPermission(state(permission("a", { groupId: "g" }), [group("g")]))).toBeUndefined();
  });

  test("errors name what is pending and what to pass", () => {
    expect(debugAnswer(state(permission("a")), { permission_id: "z" })).toEqual({
      error: "no pending permission z",
      pending: ["a"],
    });
    expect(debugAnswer(state(), {})).toEqual({ error: "no pending permission", pending: [] });
    const onlyAlways = permission("b", { options: [{ id: "allow_always", name: "Always allow", allow: true }] });
    expect(debugAnswer(state(onlyAlways), {})).toMatchObject({
      error: "permission b has no allow-once option; pass option_id (allow_always)",
    });
    expect(debugAnswer(state(permission("a")), { decision: "allow_chat" })).toMatchObject({
      error: "allow_chat answers a group; a single request takes allow, deny or option_id",
    });
  });

  test("a group takes its own decisions; allow is allow_once", () => {
    const groups = state(undefined, [group("g1"), group("g2", ["deny"])]);
    expect(debugAnswer(groups, { group_id: "g1" })).toEqual({
      kind: "group",
      groupId: "g1",
      revision: 3,
      decision: "allow_once",
    });
    expect(debugAnswer(groups, {})).toMatchObject({ error: "the group offers deny, not allow_once" });
    expect(debugAnswer(groups, { decision: "deny" })).toMatchObject({ groupId: "g2", decision: "deny" });
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
  const userRow = (text: string): AcpmuxRow => ({ id: `u-${text}`, version: 1, at: 0, kind: "user", text });
  const host = (overrides: Partial<DebugChatHost> = {}) => {
    const calls: unknown[][] = [];
    let rows: AcpmuxRow[] = [];
    let sessionId = "s1";
    const chat: DebugChatHost = {
      snapshot: () => ({ rows, sessionId, sessions: [{ sessionId: "s2" }], permission: permission("a") }) as never,
      // Like the composer's call: the prompt's row shows at once, the call settles at turn end.
      send: (text) => {
        calls.push(["send", text]);
        rows = [...rows, userRow(text)];
        return new Promise(() => {});
      },
      select: async (id) => {
        calls.push(["select", id]);
        sessionId = id;
      },
      answer: async (id, option) => calls.push(["answer", id, option]),
      respondGroup: async (id, revision, decision) => calls.push(["group", id, revision, decision]),
      openChanges: (row, path) => calls.push(["changes", row, path]),
      changesRow: () => undefined,
      ...overrides,
    };
    return { calls, debug: createAcpmuxDebug({ replaceRows: () => {}, rowCount: () => 0, chat }) };
  };

  test("send_prompt returns once the prompt shows, while the turn still runs", async () => {
    const { calls, debug } = host();
    expect(await debug.sendPrompt("run the tests")).toEqual({ sent: true, session: "s1" });
    expect(calls).toEqual([["send", "run the tests"]]);
    expect(await debug.sendPrompt("  ")).toEqual({ error: "empty prompt" });
  });

  test("send_prompt reports a send that fails", async () => {
    const offline = host({ send: () => Promise.reject(new Error("acpmux is not connected")) });
    expect(await offline.debug.sendPrompt("hi")).toEqual({ error: "acpmux is not connected" });
  });

  test("select_session waits for the select to settle and reports a failure", async () => {
    const { debug } = host();
    expect(await debug.selectSession("s2")).toEqual({ selected: "s2", listed: true, shown: true, rows: 0 });
    const failing = host({ select: () => Promise.reject(new Error("session not found")) });
    expect(await failing.debug.selectSession("nope")).toEqual({ error: "session not found", listed: false });
  });

  test("answer_permission answers through the card's path", async () => {
    const { calls, debug } = host();
    expect(await debug.answerPermission()).toMatchObject({ answered: { permissionId: "a", optionId: "allow_once" } });
    expect(calls).toEqual([["answer", "a", "allow_once"]]);
  });

  test("open_changes is open only when the asked-for turn shows", async () => {
    const { debug } = host({
      snapshot: () => ({ rows: [edit("one", "a.ts"), edit("two", "b.ts")], sessions: [] }) as never,
      changesRow: () => "one",
    });
    expect(await debug.openChanges({ row_id: "two" })).toEqual({ row: "two", open: false });
  });

  test("a page without a chat says so", async () => {
    const debug = createAcpmuxDebug({ replaceRows: () => {}, rowCount: () => 0 });
    expect(await debug.sendPrompt("x")).toEqual({ error: "this page has no chat" });
    expect(await debug.openChanges()).toEqual({ error: "this page has no chat" });
  });
});
