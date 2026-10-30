// Leo, 2026-10-19: the permission UI flickered on every tab or workspace switch. Selecting a chat
// emptied the grouped permission state (its pending asks and its "allow for this chat" grant)
// until `_acpmux/permission_groups` answered again, so the panel and the access chip's grant
// left and came back. A chat this client read before shows what it last read at once; the
// refresh that follows replaces it, and a chat never read starts empty.
import { expect, test } from "bun:test";
import { PermissionGroupClient } from "../src/agent-session/acpmux/permissions/client";

function list(sessionId: string, chatAllowance: boolean) {
  return {
    groups: [
      {
        groupId: `group-${sessionId}`,
        sessionId,
        turnId: null,
        revision: 1,
        state: "pending",
        items: [{ permissionId: `perm-${sessionId}`, request: { title: "Edit upload.sh" }, state: "pending" }],
        decisions: ["allow_once", "allow_chat", "deny"],
        decision: null,
      },
    ],
    chatAllowance: { active: chatAllowance, expires: "session_stop_or_daemon_restart" },
    coverage: { label: "acp_requests_only", isolation: "unverified", detail: "ACP requests only" },
    batching: { windowMs: 50, maxItems: 8, maxPendingGroups: 4, maxReceipts: 8 },
  };
}

const memory = new Map<string, unknown>();
const storage = {
  get: (key: string) => memory.get(key),
  set: (key: string, value: unknown) => void memory.set(key, value),
  delete: (key: string) => void memory.delete(key),
};

test("switching back to a chat shows its last read permission state before the refresh answers", async () => {
  // Each session's first read answers; every later read stays pending, as a slow acpmux after a switch.
  const answered = new Set<string>();
  const client = new PermissionGroupClient(
    async (_method, params) => {
      const sessionId = String(params.sessionId);
      if (answered.has(sessionId)) return new Promise(() => {});
      answered.add(sessionId);
      return list(sessionId, sessionId === "chat-a");
    },
    () => {},
    storage,
  );
  client.configure(true);
  client.select("chat-a");
  await client.refresh();
  expect(client.state.chatAllowance).toBe(true);
  expect(client.state.groups.map((group) => group.groupId)).toEqual(["group-chat-a"]);

  client.select("chat-b");
  expect(client.state.groups).toEqual([]);
  await client.refresh();

  client.select("chat-a");
  void client.refresh().catch(() => {});
  expect(client.state.chatAllowance).toBe(true);
  expect(client.state.groups.map((group) => group.groupId)).toEqual(["group-chat-a"]);
});

test("groups shown from a chat's last read go when its refresh fails", async () => {
  let fail = false;
  const client = new PermissionGroupClient(
    async (_method, params) => {
      if (fail) throw new Error("disconnected");
      return list(String(params.sessionId), true);
    },
    () => {},
    storage,
  );
  client.configure(true);
  client.select("chat-c");
  await client.refresh();
  client.select("chat-d");
  await client.refresh();
  fail = true;
  client.select("chat-c");
  expect(client.state.groups.length).toBe(1);
  await client.refresh().catch(() => {});
  expect(client.state.groups).toEqual([]);
  expect(client.state.chatAllowance).toBe(false);
});

test("a read's refused allows stay with its chat across a switch", async () => {
  const client = new PermissionGroupClient(
    async (_method, params) => {
      const sessionId = String(params.sessionId);
      const read = list(sessionId, false);
      return sessionId === "peer-chat" ? { ...read, allowRefused: "permission.person_required" } : read;
    },
    () => {},
    storage,
  );
  client.configure(true);
  client.select("peer-chat");
  await client.refresh();
  expect(client.state.allowRefused).toBe("permission.person_required");
  client.select("local-chat");
  expect(client.state.allowRefused).toBeUndefined();
  await client.refresh();
  expect(client.state.allowRefused).toBeUndefined();
  client.select("peer-chat");
  expect(client.state.allowRefused).toBe("permission.person_required");
});
