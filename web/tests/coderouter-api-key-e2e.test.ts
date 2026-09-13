import { expect, test } from "bun:test";

import { makeApiKeyHandlers } from "../app/api/coderouter/api-keys/route";
import { makeApiKeySelfHandlers } from "../app/api/coderouter/api-keys/self/route";
import { authenticateRequestRouteToken } from "../services/coderouter/routeTokenAuth";
import { usageEventRow } from "../services/coderouter/usageLedger";

const TEAM = "team-api-key-e2e";
const USER = "user-api-key-e2e";
const KEY_ID = "00000000-0000-4000-8000-000000000042";
const KEY = `crk_${"A".repeat(43)}`;

const context = {
  ok: true as const,
  value: {
    user: { id: USER },
    team: {
      teamId: TEAM,
      teamName: "API key test team",
      use: true,
      manageAccounts: true,
    },
  },
};

test("API key lifecycle authenticates, attributes usage, and revokes access", async () => {
  let revoked = false;
  const issued = {
    id: KEY_ID,
    key: KEY,
    keyPrefix: `${KEY.slice(0, 12)}...`,
    label: "ci",
    createdAt: new Date("2026-09-13T00:00:00Z"),
  };
  const list = async () => revoked
    ? [{
      id: KEY_ID,
      teamId: TEAM,
      stackUserId: USER,
      keyPrefix: issued.keyPrefix,
      label: issued.label,
      createdAt: issued.createdAt.toISOString(),
      lastUsedAt: null,
      revokedAt: new Date("2026-09-13T00:01:00Z").toISOString(),
    }]
    : [{
      id: KEY_ID,
      teamId: TEAM,
      stackUserId: USER,
      keyPrefix: issued.keyPrefix,
      label: issued.label,
      createdAt: issued.createdAt.toISOString(),
      lastUsedAt: null,
      revokedAt: null,
    }];
  const control = makeApiKeyHandlers({
    resolve: (async () => context) as never,
    list,
    create: async () => issued,
  });
  const created = await control.POST(new Request("https://coderouter.test/api/coderouter/api-keys", {
    method: "POST",
    body: JSON.stringify({ label: "ci" }),
    headers: { "content-type": "application/json" },
  }));
  expect(created.status).toBe(201);
  await expect(created.json()).resolves.toMatchObject({ id: KEY_ID, key: KEY, label: "ci" });

  const auth = async (token: string) => token === KEY && !revoked
    ? { teamId: TEAM, stackUserId: USER, vmId: null, apiKeyId: KEY_ID }
    : null;
  const self = makeApiKeySelfHandlers({
    authenticate: (request) => authenticateRequestRouteToken(request, auth),
    revoke: async () => {
      revoked = true;
      return true;
    },
  });
  const request = new Request("https://coderouter.test/v1/responses", {
    headers: { authorization: `Bearer ${KEY}` },
  });
  const identity = await authenticateRequestRouteToken(request, auth);
  expect(identity).toMatchObject({
    ok: true,
    identity: { teamId: TEAM, stackUserId: USER, apiKeyId: KEY_ID },
  });
  if (!identity.ok) throw new Error("API key did not authenticate");

  const row = usageEventRow({
    requestId: "00000000-0000-4000-8000-000000000043",
    teamId: TEAM,
    stackUserId: USER,
    apiKeyId: identity.identity.apiKeyId,
    vmId: null,
    provider: "codex",
    agent: "codex",
    model: "gpt-5",
    inputTokens: 10,
    cachedInputTokens: 0,
    outputTokens: 5,
    totalTokens: 15,
    status: 200,
  }, new Date("2026-09-13T00:00:30Z"));
  expect(row?.api_key_id).toBe(KEY_ID);

  expect((await self.DELETE(request)).status).toBe(204);
  expect((await self.GET(request)).status).toBe(401);
  expect((await control.GET(new Request("https://coderouter.test/api/coderouter/api-keys"))).status).toBe(200);
  await expect((await control.GET(new Request("https://coderouter.test/api/coderouter/api-keys"))).json())
    .resolves.toMatchObject({ keys: [{ id: KEY_ID, revokedAt: "2026-09-13T00:01:00.000Z" }] });
});
