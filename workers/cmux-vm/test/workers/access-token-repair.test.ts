import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CompactSign, decodeJwt, importJWK } from "jose";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let harness: Harness;

beforeEach(async () => {
  harness = await makeHarness();
});

afterEach(async () => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  await harness.dispose();
});

const create = (key: string, vmId: string, scopes: ReadonlyArray<string>, linuxUser = "cmux", ttlSeconds = 3600) =>
  harness.request("/v1/access-tokens", bearer(key), {
    method: "POST", body: { principal: "end_user", vmIds: [vmId], scopes, linuxUser, ttlSeconds },
  });

const mint = async (key: string, vmId: string, scopes: ReadonlyArray<string>, ttlSeconds = 3600) => {
  const response = await create(key, vmId, scopes, "cmux", ttlSeconds);
  expect(response.status).toBe(201);
  const body: unknown = await response.json();
  if (typeof body !== "object" || body === null || !("id" in body) || !("token" in body) || typeof body.id !== "string" || typeof body.token !== "string") {
    throw new Error("expected access token");
  }
  return { id: body.id, token: body.token };
};

const ssh = (created: { readonly id: string; readonly token: string }) =>
  harness.request(`/v1/access-tokens/${created.id}/ssh`, bearer(created.token), { method: "POST" });

const rows = async (key: string): Promise<unknown> => {
  const response = await harness.request("/v1/access-tokens", bearer(key));
  expect(response.status).toBe(200);
  return response.json();
};

describe("access-token review regressions", () => {
  it.each(["ssh", "ports"])("refuses read-only keys delegating %s", async (scope) => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:read"]);
    expect((await create(key, vmId, [scope], "root")).status).toBe(403);
    expect(harness.upstreamRequests).toHaveLength(0);
  });

  it.each(["vm:exec", "vm:terminal"] as const)("allows %s to delegate SSH", async (scope) => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", scope]);
    expect((await ssh(await mint(key, vmId, ["ssh"]))).status).toBe(200);
  });

  it("requires vm:write to delegate ports", async () => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:write"]);
    expect((await create(key, vmId, ["ports"])).status).toBe(201);
  });

  it.each(["files:read", "files:write"])("refuses non-root %s rather than silently using the provider default", async (scope) => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:files"]);
    for (const user of ["cmux", "ubuntu"]) {
      const response = await create(key, vmId, [scope], user);
      expect(response.status).toBe(400);
      expect(await response.json()).toMatchObject({ _tag: "BadRequest", message: "This provider supports file access only as root; set linuxUser to root" });
    }
    expect(harness.upstreamRequests).toHaveLength(0);
  });

  it("sweeps expired SSH identities and records revocation", async () => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:exec", "vm:read"]);
    const expired = await mint(key, vmId, ["ssh"], 1);
    expect((await ssh(expired)).status).toBe(200);
    const live = await mint(key, vmId, ["ssh"]);
    expect((await ssh(live)).status).toBe(200);
    await new Promise((resolve) => setTimeout(resolve, 1100));
    await harness.scheduled();
    expect(harness.upstream.identities.size).toBe(1);
    expect(harness.upstream.callsTo("DELETE", /\/identities\//u)).toHaveLength(1);
    expect(await rows(key)).toMatchObject({ items: expect.arrayContaining([
      expect.objectContaining({ id: expired.id, revokedAt: expect.any(String) }),
      expect.objectContaining({ id: live.id, revokedAt: null }),
    ]) });
    await harness.scheduled();
    expect(harness.upstream.callsTo("DELETE", /\/identities\//u)).toHaveLength(1);
    expect((await ssh(expired)).status).toBe(401);
  });

  it("refuses preexisting non-root file tokens before any provider call", async () => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:exec"]);
    const issued = await mint(key, vmId, ["exec"]);
    const signing = harness.accessTokenKeys()[0];
    if (signing === undefined) throw new Error("missing signing key");
    const claims = { ...decodeJwt(issued.token.slice("cmux_at_".length)), scopes: ["files:read", "files:write"], linuxUser: "cmux" };
    const signed = await new CompactSign(new TextEncoder().encode(JSON.stringify(claims)))
      .setProtectedHeader({ alg: "EdDSA", kid: signing.kid, typ: "JWT" })
      .sign(await importJWK(signing.privateJwk, "EdDSA"));
    const headers = bearer(`cmux_at_${signed}`);
    const read = await harness.request(`/v1/vms/${vmId}/files/content?path=%2Ftmp%2Fx`, headers);
    const write = await harness.send(`/v1/vms/${vmId}/files/content?path=%2Ftmp%2Fx`, headers, "PUT", new TextEncoder().encode("x"));
    const list = await harness.request(`/v1/vms/${vmId}/files/entries?path=%2Ftmp`, headers);
    for (const response of [read, write, list]) {
      expect(response.status).toBe(400);
      expect(await response.json()).toMatchObject({ _tag: "BadRequest", message: "This provider supports file access only as root; set linuxUser to root" });
    }
    expect(harness.upstreamRequests).toHaveLength(0);
  });

  it("retries failed revocations on the next sweep without waiting for expiry, and continues past failed rows", async () => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:exec", "vm:read"]);
    const first = await mint(key, vmId, ["ssh"]);
    const second = await mint(key, vmId, ["ssh"]);
    for (const token of [first, second]) {
      expect((await ssh(token)).status).toBe(200);
      harness.upstream.fail("deleteIdentity", 503);
      expect((await harness.request(`/v1/access-tokens/${token.id}`, bearer(key), { method: "DELETE" })).status).toBe(503);
      expect((await ssh(token)).status).toBe(401);
    }
    expect(await rows(key)).toMatchObject({ items: [
      expect.objectContaining({ revokedAt: expect.any(String) }),
      expect.objectContaining({ revokedAt: expect.any(String) }),
    ] });
    harness.upstream.fail("deleteIdentity", 503);
    await harness.scheduled();
    expect(harness.upstream.identities.size).toBe(1);
    await harness.scheduled();
    expect(harness.upstream.identities.size).toBe(0);
    const deletions = harness.upstream.callsTo("DELETE", /\/identities\//u).length;
    await harness.scheduled();
    expect(harness.upstream.callsTo("DELETE", /\/identities\//u)).toHaveLength(deletions);
  });

  it("deletes an identity created concurrently with revocation and returns no SSH credential", async () => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:exec", "vm:read"]);
    const token = await mint(key, vmId, ["ssh"]);
    harness.upstream.beforeNext("createIdentityToken", async () => {
      expect((await harness.request(`/v1/access-tokens/${token.id}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    });
    const response = await ssh(token);
    expect(response.status).toBe(404);
    expect(await response.json()).not.toHaveProperty("password");
    expect(harness.upstream.identities.size).toBe(0);
  });

  it.each(["expiry", "revoke"])("closes both PTY peers on %s", async (reason) => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:terminal"]);
    const token = await mint(key, vmId, ["pty"], reason === "expiry" ? 2 : 3600);
    vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout", "setInterval", "clearInterval"] });
    let providerClosed = false;
    harness.s3a.onTerminal((socket) => {
      socket.addEventListener("close", () => {
        providerClosed = true;
        socket.close();
      });
    });
    const response = await harness.request(`/v1/vms/${vmId}/terminal`, { ...bearer(token.token), upgrade: "websocket" });
    expect(response.status).toBe(101);
    const client = response.webSocket;
    if (client === null) throw new Error("expected PTY socket");
    client.accept();
    const closed = new Promise<number>((resolve) => client.addEventListener("close", (event) => {
      client.close();
      resolve(event.code);
    }));
    if (reason === "revoke") {
      expect((await harness.request(`/v1/access-tokens/${token.id}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    }
    await vi.advanceTimersByTimeAsync(reason === "expiry" ? 2100 : 30_000);
    expect(await closed).toBe(1011);
    expect(providerClosed).toBe(true);
  });

  it.each(["malformed", "duplicate", "invalid-jwk", "multiple-active"])("fails closed with redacted diagnostics for %s keys", async (failure) => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:exec"]);
    const issued = await mint(key, vmId, ["exec"]);
    const signing = harness.accessTokenKeys()[0];
    if (signing === undefined) throw new Error("missing signing key");
    const raw = failure === "malformed" ? "private-key-not-json" : JSON.stringify(failure === "duplicate" ? [signing, signing]
      : failure === "invalid-jwk" ? [{ ...signing, privateJwk: {}, publicJwk: {} }]
      : [signing, { ...signing, kid: "second-active" }]);
    const errors = vi.spyOn(console, "error");
    harness.setAccessTokenKeyConfig(raw);
    expect((await create(key, vmId, ["exec"])).status).toBe(503);
    expect((await harness.request(`/v1/vms/${vmId}/exec`, bearer(issued.token), { method: "POST", body: { command: "true" } })).status).toBe(401);
    expect(errors).toHaveBeenCalledWith(expect.stringContaining("cmux_vm_access_token_keys_invalid"));
    expect(JSON.stringify(errors.mock.calls)).not.toContain(raw);
    if (signing.privateJwk.d !== undefined) expect(JSON.stringify(errors.mock.calls)).not.toContain(signing.privateJwk.d);
  });

  it("parses valid keys and supports verification-only rotation", async () => {
    const { vmId } = harness.addVm("team_alpha");
    const key = await harness.addKey("team_alpha", ["access-token:create", "vm:exec"]);
    const keys = harness.accessTokenKeys();
    harness.setAccessTokenKeyConfig(JSON.stringify(keys));
    const issued = await mint(key, vmId, ["exec"]);
    harness.setAccessTokenKeyConfig(JSON.stringify(keys.map((entry) => ({ ...entry, active: false }))));
    expect((await create(key, vmId, ["exec"])).status).toBe(503);
    expect((await harness.request(`/v1/vms/${vmId}/exec`, bearer(issued.token), { method: "POST", body: { command: "true" } })).status).toBe(200);
  });
});
