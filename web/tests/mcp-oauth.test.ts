import { beforeEach, describe, expect, test } from "bun:test";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import {
  authorizationServerMetadata,
  clearCimdCacheForTests,
  exchangeToken,
  grantForAccessToken,
  issueAuthorizationCode,
  McpOauthError,
  protectedResourceMetadata,
  registerClient,
  revokeToken,
  validateAuthorizationRequest,
  type McpOauthClient,
  type McpOauthGrant,
  type McpOauthStore,
  type McpOauthTokenRecord,
} from "../services/mcp/oauth";
import { authenticateMcpBearer, clearMcpCallerCacheForTests } from "../services/mcp/mcpAuth";
import { callCloudMcpTool, handleCloudMcpMessage, listedTools, type CloudMcpGateway } from "../services/mcp/cloudMcp";
import { CLOUD_MCP_APP_URI, cloudMcpProfileId } from "../services/mcp/cloudMcpCloudTools";
import { toolErrorFromResponse } from "../services/mcp/cloudMcpGateway";
import type { AuthedUser } from "../services/vms/auth";

const ORIGIN = "https://cmux.com";
const RESOURCE = `${ORIGIN}/api/mcp`;
const CHATGPT_CIMD = "https://chatgpt.com/oauth/client.json";
const CHATGPT_REDIRECT = "https://chatgpt.com/connector_platform_oauth_redirect";

function memoryStore() {
  const clients = new Map<string, McpOauthClient>();
  const grants = new Map<string, McpOauthGrant>();
  const tokens = new Map<string, McpOauthTokenRecord>();
  const settings = new Map<string, Record<string, unknown>>();
  const store: McpOauthStore = {
    insertClient: async (client) => { clients.set(client.clientId, client); },
    findClient: async (clientId) => clients.get(clientId) ?? null,
    insertGrant: async (grant) => {
      const row = { ...grant, id: randomUUID(), revokedAt: null };
      grants.set(row.id, row);
      return row;
    },
    findGrant: async (id) => grants.get(id) ?? null,
    revokeGrant: async (id, at) => {
      const grant = grants.get(id);
      if (grant && !grant.revokedAt) grants.set(id, { ...grant, revokedAt: at });
    },
    touchGrant: async () => {},
    readGrantSettings: async (id) => settings.get(id) ?? {},
    writeGrantSettings: async (id, values) => { settings.set(id, values); },
    insertToken: async (token) => { tokens.set(token.tokenHash, { ...token, consumedAt: null }); },
    findToken: async (hash) => tokens.get(hash) ?? null,
    consumeToken: async (hash, at) => {
      const token = tokens.get(hash);
      if (!token || token.consumedAt) return false;
      tokens.set(hash, { ...token, consumedAt: at });
      return true;
    },
  };
  return { store, grants };
}

function pkce() {
  const verifier = randomBytes(32).toString("base64url");
  return { verifier, challenge: createHash("sha256").update(verifier).digest("base64url") };
}

const cimdFetcher = async () => ({ client_id: CHATGPT_CIMD, client_name: "ChatGPT", redirect_uris: [CHATGPT_REDIRECT] });

function authorizeParams(challenge: string, extra: Record<string, string> = {}) {
  return new URLSearchParams({
    client_id: CHATGPT_CIMD,
    redirect_uri: CHATGPT_REDIRECT,
    response_type: "code",
    code_challenge: challenge,
    code_challenge_method: "S256",
    state: "st-1",
    resource: RESOURCE,
    ...extra,
  });
}

async function authorize(store: McpOauthStore, scopes = ["machines:read", "agents:run"], teamId: string | null = "team-a") {
  const { verifier, challenge } = pkce();
  const validated = await validateAuthorizationRequest(store, authorizeParams(challenge, { scope: scopes.join(" ") }), ORIGIN, { fetchCimd: cimdFetcher });
  if (!validated.ok) throw validated.error;
  const code = await issueAuthorizationCode(store, validated.request, { stackUserId: "user-1", teamId, scopes: validated.request.scopes });
  return { code, verifier };
}

function codeForm(code: string, verifier: string, extra: Record<string, string> = {}) {
  return new URLSearchParams({
    grant_type: "authorization_code",
    client_id: CHATGPT_CIMD,
    code,
    code_verifier: verifier,
    redirect_uri: CHATGPT_REDIRECT,
    resource: RESOURCE,
    ...extra,
  });
}

async function expectOauthError(promise: Promise<unknown>, error: string) {
  try {
    await promise;
  } catch (caught) {
    expect(caught).toBeInstanceOf(McpOauthError);
    expect((caught as McpOauthError).error).toBe(error);
    return;
  }
  throw new Error(`expected ${error}`);
}

beforeEach(() => {
  clearCimdCacheForTests();
  clearMcpCallerCacheForTests();
});

describe("MCP OAuth metadata", () => {
  test("the authorization server advertises what ChatGPT requires", () => {
    const metadata = authorizationServerMetadata(ORIGIN);
    expect(metadata.issuer).toBe(ORIGIN);
    expect(metadata.code_challenge_methods_supported).toEqual(["S256"]);
    expect(metadata.authorization_response_iss_parameter_supported).toBe(true);
    expect(metadata.client_id_metadata_document_supported).toBe(true);
    expect(metadata.token_endpoint_auth_methods_supported).toEqual(["none"]);
    expect(metadata.registration_endpoint).toBe(`${ORIGIN}/api/oauth/register`);
  });

  test("the protected resource names the MCP endpoint and this issuer", () => {
    const metadata = protectedResourceMetadata(ORIGIN);
    expect(metadata.resource).toBe(RESOURCE);
    expect(metadata.authorization_servers).toEqual([ORIGIN]);
  });
});

describe("MCP OAuth clients", () => {
  test("dynamic registration accepts HTTPS and loopback redirects for public clients only", async () => {
    const { store } = memoryStore();
    const registered = await registerClient(store, { client_name: "Inspector", redirect_uris: ["http://127.0.0.1:6274/callback"] });
    expect(String(registered.client_id)).toStartWith("cmux_mcp_client_");
    expect(registered.token_endpoint_auth_method).toBe("none");
    await expectOauthError(registerClient(store, { redirect_uris: ["http://evil.example/cb"] }), "invalid_redirect_uri");
    await expectOauthError(registerClient(store, { redirect_uris: ["https://a.example/cb"], token_endpoint_auth_method: "client_secret_basic" }), "invalid_client_metadata");
  });

  test("a metadata document is fetched only from an allowed host and must name itself", async () => {
    const { store } = memoryStore();
    const { challenge } = pkce();
    const foreign = await validateAuthorizationRequest(store, authorizeParams(challenge, { client_id: "https://evil.example/client.json" }), ORIGIN, {
      fetchCimd: async () => { throw new Error("must not fetch"); },
    });
    expect(foreign.ok).toBe(false);
    const mismatch = await validateAuthorizationRequest(store, authorizeParams(challenge), ORIGIN, {
      fetchCimd: async () => ({ client_id: "https://chatgpt.com/other.json", redirect_uris: [CHATGPT_REDIRECT] }),
    });
    expect(mismatch).toMatchObject({ ok: false, redirectable: false });
  });
});

describe("MCP OAuth authorization requests", () => {
  test("an unregistered redirect URI is shown on the page, never redirected to", async () => {
    const { store } = memoryStore();
    const { challenge } = pkce();
    const result = await validateAuthorizationRequest(store, authorizeParams(challenge, { redirect_uri: "https://evil.example/cb" }), ORIGIN, { fetchCimd: cimdFetcher });
    expect(result).toMatchObject({ ok: false, redirectable: false });
  });

  test("missing PKCE and a foreign resource go back to the client as errors", async () => {
    const { store } = memoryStore();
    const noPkce = await validateAuthorizationRequest(store, authorizeParams("", { code_challenge_method: "plain" }), ORIGIN, { fetchCimd: cimdFetcher });
    expect(noPkce).toMatchObject({ ok: false, redirectable: true, redirectUri: CHATGPT_REDIRECT, state: "st-1" });
    const { challenge } = pkce();
    const foreign = await validateAuthorizationRequest(store, authorizeParams(challenge, { resource: "https://other.example/mcp" }), ORIGIN, { fetchCimd: cimdFetcher });
    expect(foreign.ok).toBe(false);
    if (!foreign.ok) expect(foreign.error.error).toBe("invalid_target");
  });

  test("unknown scopes are refused and no scope means every scope", async () => {
    const { store } = memoryStore();
    const { challenge } = pkce();
    const unknown = await validateAuthorizationRequest(store, authorizeParams(challenge, { scope: "machines:read admin" }), ORIGIN, { fetchCimd: cimdFetcher });
    expect(unknown.ok).toBe(false);
    const all = await validateAuthorizationRequest(store, authorizeParams(challenge), ORIGIN, { fetchCimd: cimdFetcher });
    expect(all.ok && all.request.scopes.length).toBe(5);
  });
});

describe("MCP OAuth tokens", () => {
  test("a code exchanges once, with the right verifier, for a token bound to its grant", async () => {
    const { store } = memoryStore();
    const { code, verifier } = await authorize(store);
    const tokens = await exchangeToken(store, codeForm(code, verifier), ORIGIN);
    expect(tokens.token_type).toBe("Bearer");
    expect(tokens.scope).toBe("machines:read agents:run");
    const grant = await grantForAccessToken(store, String(tokens.access_token));
    expect(grant).toMatchObject({ stackUserId: "user-1", teamId: "team-a" });
  });

  test("a wrong verifier, redirect URI or client fails", async () => {
    const variants: Record<string, string>[] = [
      { code_verifier: pkce().verifier },
      { redirect_uri: "https://chatgpt.com/other" },
      { client_id: "cmux_mcp_client_other" },
    ];
    for (const extra of variants) {
      const { store } = memoryStore();
      const { code, verifier } = await authorize(store);
      await expectOauthError(exchangeToken(store, codeForm(code, verifier, extra), ORIGIN), "invalid_grant");
    }
  });

  test("replaying a code revokes the tokens it already produced", async () => {
    const { store } = memoryStore();
    const { code, verifier } = await authorize(store);
    const tokens = await exchangeToken(store, codeForm(code, verifier), ORIGIN);
    await expectOauthError(exchangeToken(store, codeForm(code, verifier), ORIGIN), "invalid_grant");
    expect(await grantForAccessToken(store, String(tokens.access_token))).toBeNull();
  });

  test("refresh rotates, and reusing an old refresh token ends the connection", async () => {
    const { store } = memoryStore();
    const { code, verifier } = await authorize(store);
    const first = await exchangeToken(store, codeForm(code, verifier), ORIGIN);
    const refreshForm = (token: unknown) => new URLSearchParams({ grant_type: "refresh_token", client_id: CHATGPT_CIMD, refresh_token: String(token) });
    const second = await exchangeToken(store, refreshForm(first.refresh_token), ORIGIN);
    expect(second.access_token).not.toBe(first.access_token);
    await expectOauthError(exchangeToken(store, refreshForm(first.refresh_token), ORIGIN), "invalid_grant");
    expect(await grantForAccessToken(store, String(second.access_token))).toBeNull();
  });

  test("a refresh cannot widen scopes, and client secrets are refused", async () => {
    const { store } = memoryStore();
    const { code, verifier } = await authorize(store, ["machines:read"]);
    const tokens = await exchangeToken(store, codeForm(code, verifier), ORIGIN);
    await expectOauthError(exchangeToken(store, new URLSearchParams({
      grant_type: "refresh_token", client_id: CHATGPT_CIMD, refresh_token: String(tokens.refresh_token), scope: "machines:read machines:write",
    }), ORIGIN), "invalid_scope");
    await expectOauthError(exchangeToken(store, codeForm("x", "y", { client_secret: "s" }), ORIGIN), "invalid_client");
  });

  test("an access token expires, and revocation ends its grant", async () => {
    const { store } = memoryStore();
    const { code, verifier } = await authorize(store);
    const tokens = await exchangeToken(store, codeForm(code, verifier), ORIGIN);
    expect(await grantForAccessToken(store, String(tokens.access_token), new Date(Date.now() + 2 * 60 * 60 * 1000))).toBeNull();
    await revokeToken(store, new URLSearchParams({ token: String(tokens.refresh_token) }));
    expect(await grantForAccessToken(store, String(tokens.access_token))).toBeNull();
  });
});

function authedUser(teamIds: string[]): AuthedUser {
  return {
    id: "user-1",
    displayName: "Ada",
    primaryEmail: "ada@example.com",
    billingCustomerType: "team",
    billingTeamId: teamIds[0] ?? "user-1",
    selectedTeamId: teamIds[0] ?? null,
    teams: teamIds.map((id) => ({ id, displayName: id, billingPlanId: "pro", billingSeats: 1 })),
    teamIds,
    userBillingPlanId: "pro",
    billingPlanId: "pro",
    billingSeats: 1,
  };
}

describe("MCP bearer authentication", () => {
  test("a live token resolves its user; a foreign or stale token is invalid; a Stack bearer is not an MCP token", async () => {
    const { store } = memoryStore();
    const { code, verifier } = await authorize(store);
    const tokens = await exchangeToken(store, codeForm(code, verifier), ORIGIN);
    const request = (token: string) => new Request(RESOURCE, { method: "POST", headers: { authorization: `Bearer ${token}` } });
    const ok = await authenticateMcpBearer(request(String(tokens.access_token)), store, { resolveUser: async () => authedUser(["team-a"]) });
    expect(ok.kind).toBe("oauth");
    expect(await authenticateMcpBearer(request("cmux_mcp_at_unknown"), store, { resolveUser: async () => authedUser(["team-a"]) })).toEqual({ kind: "invalid" });
    expect(await authenticateMcpBearer(request("eyJhbGciOi.stack.jwt"), store)).toEqual({ kind: "none" });
  });

  test("a user who left the grant's team loses access", async () => {
    const { store } = memoryStore();
    const { code, verifier } = await authorize(store);
    const tokens = await exchangeToken(store, codeForm(code, verifier), ORIGIN);
    const request = new Request(RESOURCE, { method: "POST", headers: { authorization: `Bearer ${tokens.access_token}` } });
    expect(await authenticateMcpBearer(request, store, { resolveUser: async () => authedUser(["team-b"]) })).toEqual({ kind: "invalid" });
  });
});

function scopedGateway(scopes: readonly string[] | null, overrides: Partial<CloudMcpGateway> = {}): CloudMcpGateway {
  let settings: Record<string, unknown> = {};
  return {
    scopes,
    insufficientScopeChallenge: (scope) => `Bearer error="insufficient_scope", scope="${scope}"`,
    listMachines: async () => [{ id: "vm-a", name: "alpha", status: "running" }],
    runCmuxTui: async () => { throw new Error("no guest call expected"); },
    profile: async () => ({ id: cloudMcpProfileId("user-1", "team-a"), email: "ada@example.com" }),
    account: async () => ({ planId: "free", teamName: "Ada's team", maxActiveVms: 0, activeVmCount: 0, memoryOptionsMb: [] }),
    createMachine: async () => { throw new Error("no create expected"); },
    setMachineState: async (id, action) => ({ id, name: null, status: action === "pause" ? "paused" : "running" }),
    deleteMachine: async () => {},
    readSettings: async () => settings,
    writeSettings: async (values) => { settings = values; },
    ...overrides,
  };
}

describe("MCP tool scopes", () => {
  test("tools/list shows only tools the connection was granted", () => {
    const names = listedTools(scopedGateway(["machines:read"])).map((tool) => tool.name);
    expect(names).toContain("list_machines");
    expect(names).toContain("get_profile");
    expect(names).not.toContain("send_input");
    expect(names).not.toContain("delete_machine");
    expect(listedTools(scopedGateway(["machines:read"])).every((tool) => !("requiredScope" in tool))).toBe(true);
  });

  test("an ungranted tool asks the host to reconnect and runs nothing", async () => {
    const result = await callCloudMcpTool(scopedGateway(["machines:read"]), "delete_machine", { machine_id: "vm-a" });
    expect(result.isError).toBe(true);
    expect(result.structuredContent).toMatchObject({ error: "insufficient_scope", scope: "machines:write" });
    expect(result._meta?.["mcp/www_authenticate"]).toEqual(['Bearer error="insufficient_scope", scope="machines:write"']);
  });

  test("a plan without Cloud explains it and links the pricing page, without an upgrade call to action", async () => {
    const account = await callCloudMcpTool(scopedGateway(["machines:read"]), "get_account", {});
    expect(account.structuredContent).toMatchObject({ cloud_included: false, plan_info_url: "https://cmux.com/pricing" });
    const refusal = await toolErrorFromResponse(new Response(JSON.stringify({
      error: "vm_requires_pro", message: "Cloud VMs require a cmux Pro plan.", action: "Upgrade to cmux Pro at https://cmux.com/pricing", upgradeRequired: true,
    }), { status: 402 }));
    expect(refusal.code).toBe("vm_requires_pro");
    expect(refusal.details).toMatchObject({ plan_required: true, plan_info_url: "https://cmux.com/pricing" });
    expect(refusal.message).not.toMatch(/upgrade/i);
  });

  test("settings read every value and update only valid ones", async () => {
    const gateway = scopedGateway(["machines:read"]);
    const read = await callCloudMcpTool(gateway, "read_settings", {});
    expect(read.structuredContent).toMatchObject({ values: { default_agent: "codex", default_size_gb: "8", auto_pause_after_agent: false } });
    const updated = await callCloudMcpTool(gateway, "update_settings", { set: { default_agent: "claude" } });
    expect(updated.structuredContent).toMatchObject({ values: { default_agent: "claude", default_size_gb: "8" } });
    const invalid = await callCloudMcpTool(gateway, "update_settings", { set: { default_agent: "rm -rf" } });
    expect(invalid.isError).toBe(true);
  });

  test("the profile id is stable per user and team and distinct across teams", async () => {
    expect(cloudMcpProfileId("user-1", "team-a")).toBe(cloudMcpProfileId("user-1", "team-a"));
    expect(cloudMcpProfileId("user-1", "team-a")).not.toBe(cloudMcpProfileId("user-1", "team-b"));
    expect(cloudMcpProfileId("user-1", "team-a")).not.toContain("user-1");
  });
});

describe("MCP App and extensions", () => {
  test("initialize advertises settings tools, and the UI resource is readable HTML", async () => {
    const gateway = scopedGateway(null);
    const init = await handleCloudMcpMessage(gateway, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25" } });
    expect(init).toMatchObject({ result: { capabilities: { extensions: { "openai/settings": { readTool: "read_settings", updateTool: "update_settings" } } } } });
    const read = await handleCloudMcpMessage(gateway, { jsonrpc: "2.0", id: 2, method: "resources/read", params: { uri: CLOUD_MCP_APP_URI } }) as { result: { contents: Array<{ mimeType: string; text: string }> } };
    expect(read.result.contents[0]!.mimeType).toBe("text/html;profile=mcp-app");
    expect(read.result.contents[0]!.text).toContain("ui/initialize");
  });

  test("open_cloud is a sidebar and thread entrypoint that accepts {}", async () => {
    const tool = listedTools(scopedGateway(null)).find((candidate) => candidate.name === "open_cloud") as Record<string, any>;
    expect(tool._meta["openai/ui"].entrypoints).toEqual([{ type: "global" }, { type: "thread" }]);
    expect(tool._meta.ui.resourceUri).toBe(CLOUD_MCP_APP_URI);
    const result = await callCloudMcpTool(scopedGateway(null), "open_cloud", {});
    expect(result.structuredContent).toMatchObject({ view: "cloud", machines: [{ id: "vm-a" }] });
  });
});
