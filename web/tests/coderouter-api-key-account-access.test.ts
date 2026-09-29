import { describe, expect, test } from "bun:test";
import { sql } from "drizzle-orm";
import { PgDialect } from "drizzle-orm/pg-core";
import {
  accountAccessForIdentity,
  accountAccessPredicate,
  scopedSessionKey,
  type CoderouterAccountAccess,
} from "../services/coderouter/accountAccess";
import { createClaudeMessagesProxy } from "../services/coderouter/claudeProxy";
import { createCodexResponsesProxy } from "../services/coderouter/codexProxy";

// A `crk_` API key is a team credential held by scripts and agents. In an
// organization it must not carry its creator's private account access
// (https://github.com/manaflow-ai/cmux/issues/14404).

const ORG_KEY = { teamId: "org-1", stackUserId: "admin-1", vmId: null, apiKeyId: "key-1" } as const;
const PERSONAL_KEY = { teamId: "user-1", stackUserId: "user-1", vmId: null, apiKeyId: "key-2" } as const;

describe("API-key account access", () => {
  const dialect = new PgDialect();
  const account = { id: sql`a.id`, teamId: sql`a.team_id`, visibility: sql`a.visibility`, createdBy: sql`a.created_by` };
  const render = (access: CoderouterAccountAccess, family: "native" | "claude" = "native") =>
    dialect.sqlToQuery(accountAccessPredicate(account, family, access));

  test("an organization key maps to a team-key scope without its creator's private access", () => {
    expect(accountAccessForIdentity(ORG_KEY)).toEqual({ kind: "api-key", apiKeyId: "key-1", teamId: "org-1", personal: false });
  });

  test("a personal-team key keeps its owner's private access", () => {
    expect(accountAccessForIdentity(PERSONAL_KEY)).toEqual({ kind: "api-key", apiKeyId: "key-2", teamId: "user-1", personal: true });
  });

  test("route tokens, VMs, and chatmux machines keep their existing scopes", () => {
    expect(accountAccessForIdentity({ teamId: "org-1", stackUserId: "admin-1", vmId: null }))
      .toEqual({ kind: "user", userId: "admin-1" });
    expect(accountAccessForIdentity({ teamId: "org-1", stackUserId: "admin-1", vmId: "vm-1", poolId: "pool-1" }))
      .toEqual({ kind: "vm", vmId: "vm-1", poolId: "pool-1", creatorUserId: "admin-1" });
    expect(accountAccessForIdentity({ teamId: "org-1", stackUserId: "admin-1", vmId: "chatmux:m", machine: "chatmux" }))
      .toEqual({ kind: "team-machine", teamId: "org-1", machineId: "chatmux:m" });
  });

  test("an organization key matches only accounts its team shares, for both families", () => {
    for (const family of ["native", "claude"] as const) {
      const q = render(accountAccessForIdentity(ORG_KEY), family);
      expect(q.sql).toBe("(a.team_id = $1 and a.visibility = 'team')");
      expect(q.params).toEqual(["org-1"]);
    }
  });

  test("a personal-team key matches shared accounts and the owner's private imports in that scope", () => {
    const q = render(accountAccessForIdentity(PERSONAL_KEY));
    expect(q.sql).toBe("(a.team_id = $1 and (a.visibility = 'team' or a.created_by = $2))");
    expect(q.params).toEqual(["user-1", "user-1"]);
  });

  test("an API-key scope with an empty team id matches nothing", () => {
    expect(render({ kind: "api-key", apiKeyId: "k", teamId: "", personal: false }).sql).toBe("false");
    expect(render({ kind: "api-key", apiKeyId: "k", teamId: "", personal: true }).sql).toBe("false");
  });

  test("an API key never reuses its creator's user-scoped sticky session", () => {
    const user = scopedSessionKey("s", accountAccessForIdentity({ ...ORG_KEY, apiKeyId: null }));
    const key = scopedSessionKey("s", accountAccessForIdentity(ORG_KEY));
    const otherKey = scopedSessionKey("s", accountAccessForIdentity({ ...ORG_KEY, apiKeyId: "key-3" }));
    expect(key).not.toBe(user);
    expect(key).not.toBe(otherKey);
    expect(key).toBe(JSON.stringify(["api-key", "key-1", "s"]));
  });
});

describe("data-plane proxies pass the API-key scope to account selection", () => {
  test("Codex responses selection receives the organization key scope", async () => {
    const seen: unknown[] = [];
    const proxy = createCodexResponsesProxy({
      authenticate: async () => ({ teamId: "org-1", stackUserId: "admin-1", vmId: null, apiKeyId: "key-1" }),
      select: async (input) => {
        seen.push(input.access);
        return null;
      },
      credential: async () => { throw new Error("no account should be selected"); },
      cooldown: async () => {},
    }, { fetch: async () => { throw new Error("no upstream call expected"); } });
    const response = await proxy(new Request("https://coderouter.test/v1/responses", {
      method: "POST",
      headers: { authorization: `Bearer crk_${"a".repeat(43)}`, "content-type": "application/json" },
      body: JSON.stringify({ model: "gpt-test", input: [] }),
    }));
    expect(response.status).toBe(503);
    expect(seen).toEqual([{ kind: "api-key", apiKeyId: "key-1", teamId: "org-1", personal: false }]);
  });

  test("Claude messages selection receives the organization key scope", async () => {
    const seen: unknown[] = [];
    const messages = createClaudeMessagesProxy({
      authenticate: async () => ({
        ok: true,
        identity: { teamId: "org-1", stackUserId: "admin-1", vmId: null, token: "crk_x", apiKeyId: "key-1" },
      }),
      select: async (_teamId, input) => {
        seen.push(input.access);
        return { kind: "none" };
      },
      cooldown: async () => {},
      touchUsed: async () => {},
      fetch: (async () => { throw new Error("no upstream call expected"); }) as unknown as typeof fetch,
      now: () => new Date("2026-09-27T00:00:00.000Z"),
      capture: () => {},
    });
    await messages(new Request("https://coderouter.test/v1/messages", {
      method: "POST",
      headers: { "x-api-key": "crk_x", "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: "claude-sonnet-4-5", max_tokens: 8, messages: [] }),
    }));
    expect(seen).toEqual([{ kind: "api-key", apiKeyId: "key-1", teamId: "org-1", personal: false }]);
  });
});
