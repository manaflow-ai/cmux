import { describe, expect, test } from "bun:test";
import {
  PERMISSION_GROUP_OPS,
  permissionGroups,
  supportsPermissionGroups,
  type PermissionGroup,
  type PermissionGroupList,
} from "./protocol";
import { PermissionGroupClient, type PermissionStorage, type Request } from "./client";

const group: PermissionGroup = {
  groupId: "group-1",
  sessionId: "session-1",
  turnId: "turn-1",
  revision: 2,
  state: "pending",
  items: [
    {
      permissionId: "permission-1",
      request: {
        toolCall: { kind: "edit", title: "Write app.ts" },
        options: [{ optionId: "allow", kind: "allow_once" }],
      },
      state: "pending",
    },
  ],
  decisions: ["allow_once", "allow_chat", "deny"],
  decision: null,
};

const list: PermissionGroupList = {
  groups: [group],
  chatAllowance: { active: false, expires: "session_stop_or_daemon_restart" },
  coverage: {
    label: "acp_requests_only",
    isolation: "unverified",
    detail: "ACP requests only",
  },
  batching: { windowMs: 100, maxItems: 32, maxPendingGroups: 64, maxReceipts: 64 },
};

class MemoryStorage implements PermissionStorage {
  values = new Map<string, unknown>();
  get(key: string): unknown {
    return this.values.get(key);
  }
  set(key: string, value: unknown): void {
    this.values.set(key, value);
  }
  delete(key: string): void {
    this.values.delete(key);
  }
}

function initialized(operations: string[]) {
  return { _meta: { acpmux: { operations } } };
}

function receipt(next: PermissionGroup = { ...group, state: "resolved", decision: "allow_once" as const }) {
  return { group: next, replayed: false };
}

describe("grouped permission protocol", () => {
  test("gates on all three daemon operations and rejects malformed owner data", () => {
    expect(supportsPermissionGroups(initialized(Object.values(PERMISSION_GROUP_OPS)))).toBe(true);
    expect(supportsPermissionGroups(initialized([PERMISSION_GROUP_OPS.groups, PERMISSION_GROUP_OPS.respond]))).toBe(
      false,
    );
    expect(() =>
      permissionGroups({ ...list, groups: [{ ...group, decisions: ["allow_once", "allow_once"] }] }),
    ).toThrow("Invalid permission decisions");
    expect(() => permissionGroups({ ...list, coverage: { ...list.coverage, isolation: "verified" } })).toThrow(
      "Invalid permission coverage",
    );
  });

  test("does not mutate until an authoritative read has succeeded", async () => {
    const calls: string[] = [];
    const request: Request = async (method) => {
      calls.push(method);
      return list;
    };
    const client = new PermissionGroupClient(request, () => {}, new MemoryStorage());
    client.configure(true);
    client.select("session-1");
    await expect(client.respond("group-1", 2, "allow_once")).rejects.toMatchObject({ reason: "read_required" });
    expect(calls).toEqual([]);
  });

  test("a competing answer gets the daemon's stale revision and never partially updates local state", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const request: Request = async (method, params) => {
      calls.push({ method, params });
      if (method === PERMISSION_GROUP_OPS.groups) return list;
      throw { code: "-32000", data: { reason: "stale_revision", group: { ...group, revision: 3 } } };
    };
    const client = new PermissionGroupClient(request, () => {}, new MemoryStorage());
    client.configure(true);
    client.select("session-1");
    await client.refresh();
    await expect(client.respond("group-1", 2, "deny")).rejects.toMatchObject({ reason: "stale_revision" });
    expect(client.state.groups[0]?.revision).toBe(2);
    expect(calls.map((call) => call.method)).toEqual([PERMISSION_GROUP_OPS.groups, PERMISSION_GROUP_OPS.respond]);
  });

  test("an uncertain response reads first and retries the identical full decision body and key", async () => {
    const storage = new MemoryStorage();
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    let attempts = 0;
    const request: Request = async (method, params) => {
      calls.push({ method, params });
      if (method === PERMISSION_GROUP_OPS.groups) return list;
      attempts += 1;
      if (attempts === 1) throw { code: "native.timed_out", origin: "native", message: "Timed out" };
      return { ...receipt(), replayed: true };
    };
    const client = new PermissionGroupClient(request, () => {}, storage);
    client.configure(true);
    client.select("session-1");
    await client.refresh();
    await expect(client.respond("group-1", 2, "allow_once")).rejects.toMatchObject({ uncertain: true });
    expect(client.state.uncertain).toBe(true);
    await client.retry();
    const writes = calls.filter((call) => call.method === PERMISSION_GROUP_OPS.respond);
    expect(calls.map((call) => call.method)).toEqual([
      PERMISSION_GROUP_OPS.groups,
      PERMISSION_GROUP_OPS.respond,
      PERMISSION_GROUP_OPS.groups,
      PERMISSION_GROUP_OPS.respond,
    ]);
    expect(writes[0]?.params).toEqual(writes[1]?.params);
    expect(client.state.uncertain).toBe(false);
  });

  test("late refresh from an old selection cannot replace the new session", async () => {
    let resolveOld!: (value: unknown) => void;
    const old = new Promise((resolve) => {
      resolveOld = resolve;
    });
    const request: Request = async (_method, params) => (params.sessionId === "old" ? old : { ...list, groups: [] });
    const client = new PermissionGroupClient(request, () => {}, new MemoryStorage());
    client.configure(true);
    client.select("old");
    const pending = client.refresh();
    client.select("new");
    await client.refresh();
    resolveOld({ ...list, groups: [{ ...group, sessionId: "old" }] });
    await pending;
    expect(client.state.groups).toEqual([]);
  });

  test("a second click cannot create a second decision key while the first is saving", async () => {
    const storage = new MemoryStorage();
    let resolveResponse!: (value: unknown) => void;
    const response = new Promise((resolve) => {
      resolveResponse = resolve;
    });
    const request: Request = async (method) => (method === PERMISSION_GROUP_OPS.groups ? list : response);
    const client = new PermissionGroupClient(request, () => {}, storage);
    client.configure(true);
    client.select("session-1");
    await client.refresh();
    const first = client.respond("group-1", 2, "allow_once");
    await expect(client.respond("group-1", 2, "deny")).rejects.toMatchObject({ reason: "busy" });
    resolveResponse(receipt());
    await first;
  });

  test("a newer refresh wins when two reads overlap", async () => {
    let resolveFirst!: (value: unknown) => void;
    let reads = 0;
    const first = new Promise((resolve) => {
      resolveFirst = resolve;
    });
    const request: Request = async () => {
      reads += 1;
      return reads === 1 ? first : { ...list, groups: [] };
    };
    const client = new PermissionGroupClient(request, () => {}, new MemoryStorage());
    client.configure(true);
    client.select("session-1");
    const old = client.refresh();
    await client.refresh();
    resolveFirst(list);
    await old;
    expect(client.state.groups).toEqual([]);
  });

  test("selection changes during receipt persistence stop delivery and keep the old session key", async () => {
    const storage = new MemoryStorage();
    let releaseGet!: () => void;
    const getGate = new Promise<void>((resolve) => {
      releaseGet = resolve;
    });
    const originalGet = storage.get.bind(storage);
    let firstRead = true;
    storage.get = async (key) => {
      if (firstRead) {
        firstRead = false;
        return originalGet(key);
      }
      await getGate;
      return originalGet(key);
    };
    const methods: string[] = [];
    const request: Request = async (method) => {
      methods.push(method);
      return list;
    };
    const client = new PermissionGroupClient(request, () => {}, storage);
    client.configure(true);
    client.select("session-1");
    await client.refresh();
    const pending = client.respond("group-1", 2, "allow_once");
    client.select("session-2");
    releaseGet();
    await expect(pending).rejects.toMatchObject({ reason: "selection_changed" });
    expect(methods).toEqual([PERMISSION_GROUP_OPS.groups]);
  });

  test.each([
    { operation: "refresh", state: "resolved", deletion: 1 },
    { operation: "retry", state: "resolved", deletion: 2 },
    { operation: "retry", state: "pending", deletion: 1 },
  ] as const)(
    "$operation cleanup of a $state group cannot overwrite another chat",
    async ({ operation, state, deletion }) => {
      const storage = new MemoryStorage();
      storage.values.set("cmux.permission.group:session-1", {
        sessionId: "session-1",
        groupId: "group-1",
        revision: 2,
        decision: "allow_once",
        decisionKey: "saved-key",
      });
      let release!: () => void;
      let entered!: () => void;
      const waiting = new Promise<void>((resolve) => {
        entered = resolve;
      });
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      let deletions = 0;
      storage.delete = async (key) => {
        if (++deletions === deletion) {
          entered();
          await gate;
        }
        storage.values.delete(key);
      };
      const client = new PermissionGroupClient(
        async (_method, params) => {
          if (params.sessionId === "session-2")
            throw { code: "native.timed_out", origin: "native", message: "New chat read timed out" };
          return {
            ...list,
            groups: [
              {
                ...group,
                state,
                revision: state === "pending" ? 3 : 2,
                decision: state === "resolved" ? "allow_once" : null,
              },
            ],
          };
        },
        () => {},
        storage,
      );
      client.configure(true);
      client.select("session-1");
      const old = (operation === "retry" ? client.retry() : client.refresh()).catch(() => {});
      await waiting;
      client.select("session-2");
      await expect(client.refresh()).rejects.toMatchObject({ uncertain: true });
      const current = { ...client.state };
      release();
      await old;
      expect(client.state).toEqual(current);
      expect(client.state.error).toBe("New chat read timed out");
      expect(client.state.uncertain).toBe(true);
    },
  );

  test("a fresh client restores read-first retry for its durable pending decision", async () => {
    const storage = new MemoryStorage();
    const pending = { sessionId: "session-1", groupId: "group-1", revision: 2, decision: "allow_once", decisionKey: "before-reconnect" };
    storage.values.set("cmux.permission.group:session-1", pending);
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const client = new PermissionGroupClient(async (method, params) => {
      calls.push({ method, params });
      return method === PERMISSION_GROUP_OPS.groups ? list : receipt();
    }, () => {}, storage);
    client.configure(true);
    client.select("session-1");
    await client.refresh();
    expect(client.state.uncertain).toBe(true);
    expect(client.state.error).toBeTruthy();
    await expect(client.respond("group-1", 2, "deny")).rejects.toMatchObject({ reason: "uncertain" });
    await client.retry();
    expect(calls.map((call) => call.method)).toEqual([PERMISSION_GROUP_OPS.groups, PERMISSION_GROUP_OPS.groups, PERMISSION_GROUP_OPS.respond]);
    expect(calls[2]?.params).toEqual(pending);
    expect(client.state.uncertain).toBe(false);
    expect(storage.values.size).toBe(0);
  });

  test("wrong-session owner data never becomes ready or gets adopted", async () => {
    const wrong = { ...list, groups: [{ ...group, sessionId: "other-session" }] };
    const client = new PermissionGroupClient(
      async () => wrong,
      () => {},
      new MemoryStorage(),
    );
    client.configure(true);
    client.select("session-1");
    await expect(client.refresh()).rejects.toMatchObject({ reason: "invalid_scope" });
    expect(client.state.ready).toBe(false);
    expect(client.state.groups).toEqual([]);
  });

  test("wrong-group receipt is uncertain and remains retryable", async () => {
    const storage = new MemoryStorage();
    const request: Request = async (method) => {
      if (method === PERMISSION_GROUP_OPS.groups) return list;
      return { ...receipt(), group: { ...group, groupId: "other-group" } };
    };
    const client = new PermissionGroupClient(request, () => {}, storage);
    client.configure(true);
    client.select("session-1");
    await client.refresh();
    await expect(client.respond("group-1", 2, "allow_once")).rejects.toMatchObject({ uncertain: true });
    expect(client.state.uncertain).toBe(true);
    expect(storage.values.size).toBe(1);
  });

  test("retry evicted pending group clears its key and allows a later group", async () => {
    const storage = new MemoryStorage();
    let current: PermissionGroupList = list;
    let responseAttempts = 0;
    const nextGroup = { ...group, groupId: "group-2", revision: 1 };
    const request: Request = async (method) => {
      if (method === PERMISSION_GROUP_OPS.groups) {
        return responseAttempts === 1 ? { ...current, groups: [] } : current;
      }
      responseAttempts += 1;
      if (responseAttempts === 1) throw { code: "native.timed_out", origin: "native" };
      return { group: nextGroup, replayed: false };
    };
    const client = new PermissionGroupClient(request, () => {}, storage);
    client.configure(true);
    client.select("session-1");
    await client.refresh();
    await expect(client.respond("group-1", 2, "allow_once")).rejects.toMatchObject({ uncertain: true });
    await expect(client.retry()).rejects.toMatchObject({ code: "resource.not_found" });
    expect(storage.values.size).toBe(0);
    expect(client.state.uncertain).toBe(false);
    current = { ...list, groups: [nextGroup] };
    responseAttempts = 2;
    await client.refresh();
    await client.respond("group-2", 1, "allow_once");
    expect(client.state.groups[0]?.groupId).toBe("group-2");
  });

  test("a timed out revoke is read before the explicit retry", async () => {
    const calls: string[] = [];
    let revokeAttempts = 0;
    const request: Request = async (method) => {
      calls.push(method);
      if (method === PERMISSION_GROUP_OPS.groups)
        return { ...list, chatAllowance: { ...list.chatAllowance, active: true } };
      revokeAttempts += 1;
      if (revokeAttempts === 1) throw { code: "native.timed_out", origin: "native" };
      return { active: false };
    };
    const client = new PermissionGroupClient(request, () => {}, new MemoryStorage());
    client.configure(true);
    client.select("session-1");
    await client.refresh();
    await expect(client.revoke()).rejects.toMatchObject({ uncertain: true });
    await client.retry();
    expect(calls).toEqual([
      PERMISSION_GROUP_OPS.groups,
      PERMISSION_GROUP_OPS.revoke,
      PERMISSION_GROUP_OPS.groups,
      PERMISSION_GROUP_OPS.revoke,
    ]);
    expect(client.state.chatAllowance).toBe(false);
  });

  test("same selection preserves an in-flight recovery read, while a disconnect invalidates it", async () => {
    let resolveRead!: (value: unknown) => void;
    const request: Request = async () => new Promise((resolve) => (resolveRead = resolve));
    const client = new PermissionGroupClient(request, () => {}, new MemoryStorage());
    client.configure(true);
    client.select("session-1");
    const pending = client.refresh();
    client.select("session-1");
    client.disconnected();
    resolveRead(list);
    await pending;
    expect(client.state.loading).toBe(true);
    expect(client.state.groups).toEqual([]);
  });
});
