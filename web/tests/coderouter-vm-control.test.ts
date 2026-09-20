import { describe, expect, test } from "bun:test";
import { makeCoderouterAccountsPostHandler } from "../app/api/coderouter/accounts/route";
import { makeClaudeUpstreamHandlers } from "../app/api/coderouter/claude-upstream/route";

const vmContext = {
  ok: true as const,
  value: {
    user: { id: "creator-user" },
    team: { teamId: "team-vm", teamName: "team-vm", use: true, manageAccounts: true },
    access: { kind: "vm" as const, vmId: "vm-1", poolId: "pool-1" },
  },
};

describe("VM-bound CodeRouter control routes", () => {
  test("forces native account imports into the VM's team pool", async () => {
    let received: unknown[] = [];
    const handler = makeCoderouterAccountsPostHandler({
      resolveContext: async () => vmContext,
      add: async (...args) => {
        received = args;
        return { accountId: "account-1", alreadyExists: false };
      },
    });
    const response = await handler(new Request("https://coderouter.test/api/coderouter/accounts", {
      method: "POST",
      body: JSON.stringify({ provider: "openai-apikey", apiKey: "sk-test-key-1234567890", visibility: "private" }),
    }));
    expect(response.status).toBe(201);
    expect(received[0]).toBe("team-vm");
    expect((received[5] as { createdBy: string; visibility: string })).toEqual({
      createdBy: "creator-user",
      visibility: "team",
    });
  });

  test("allows Claude mutations through the VM pool and preserves access scoping", async () => {
    let receivedAccess: unknown;
    const handlers = makeClaudeUpstreamHandlers({
      resolveUsageTeam: async () => ({ ok: true as const, teamId: "team-vm", stackUserId: "creator-user", access: vmContext.value.access }),
      resolveContext: async () => vmContext,
      list: async (_team, access) => {
        receivedAccess = access;
        return [];
      },
      add: async (_team, _user, _input, visibility) => {
        expect(visibility).toBe("team");
        return { id: "claude-1", label: "VM Claude", state: "active", identifier: "masked" } as never;
      },
      removeAll: async () => ({ removed: 1 }),
    });
    const response = await handlers.POST(new Request("https://coderouter.test/api/coderouter/claude-upstream", {
      method: "POST",
      body: JSON.stringify({ kind: "anthropic_api_key", apiKey: "sk-ant-test-key-12345678901234567890", label: "VM Claude", visibility: "private" }),
    }));
    expect(response.status).toBe(201);
    expect(receivedAccess).toEqual(vmContext.value.access);
  });
});
