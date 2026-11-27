/**
 * API key management (cx-b4h.12): create, list and revoke the caller's
 * tenant's cmux VM API keys. Allowed for a key with the `admin` scope or a
 * session of a team admin; a new key never exceeds its issuer.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const KEY_PATTERN = /^cmuxvm_sk_[A-Za-z0-9_-]{43}$/;
const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

interface CreatedKey {
  readonly id: string;
  readonly name: string;
  readonly key: string;
  readonly scopes: ReadonlyArray<string>;
  readonly resourceAllowlist: ReadonlyArray<string> | null;
}

const create = (headers: Record<string, string>, body: unknown) => h.request("/v1/api-keys", headers, { method: "POST", body });

describe("create", () => {
  it("returns the full key once, stores only its hash, and the key works", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const admin = await h.addKey(TENANT_A, ["admin", "vm:read"]);

    const response = await create(bearer(admin), { name: "ci", scopes: ["vm:read"] });

    expect(response.status).toBe(201);
    const created = await response.json<CreatedKey>();
    expect(created.key).toMatch(KEY_PATTERN);
    expect(created.id).toMatch(/^vmk_[0-9a-hjkmnp-tv-z]{26}$/);
    expect(created).toMatchObject({ name: "ci", scopes: ["vm:read"], resourceAllowlist: null });
    expect(JSON.stringify(h.storedKeys())).not.toContain(created.key);
    expect((await h.request(`/v1/vms/${vmId}`, bearer(created.key))).status).toBe(200);

    const listed = await (await h.request("/v1/api-keys", bearer(admin))).text();
    expect(listed).toContain(created.id);
    expect(listed).not.toContain(created.key);
    expect(listed).not.toMatch(/[0-9a-f]{64}/);
  });

  it("audits the create with the new key's id", async () => {
    const admin = await h.addKey(TENANT_A, ["admin", "vm:read"]);
    const created = await (await create(bearer(admin), { name: "ci", scopes: ["vm:read"] })).json<CreatedKey>();
    expect(h.audit).toMatchObject([{ tenantId: TENANT_A, action: "apikey.create", cmuxId: created.id, outcome: "ok" }]);
  });

  it("refuses scopes the issuer does not hold", async () => {
    const admin = await h.addKey(TENANT_A, ["admin", "vm:read"]);
    const response = await create(bearer(admin), { name: "wide", scopes: ["vm:read", "vm:write"] });
    expect(response.status).toBe(403);
    expect(h.storedKeys().filter((key) => key.tenantId === TENANT_A)).toHaveLength(1);
  });

  it("keeps a key with a resource allowlist inside that allowlist", async () => {
    const a = h.addVm(TENANT_A);
    const b = h.addVm(TENANT_A);
    const admin = await h.addKey(TENANT_A, ["admin", "vm:read"], { allowlist: [a.vmId] });

    expect((await create(bearer(admin), { name: "all", scopes: ["vm:read"] })).status).toBe(403);
    expect((await create(bearer(admin), { name: "other", scopes: ["vm:read"], resourceAllowlist: [b.vmId] })).status).toBe(403);
    const ok = await create(bearer(admin), { name: "same", scopes: ["vm:read"], resourceAllowlist: [a.vmId] });
    expect(ok.status).toBe(201);
    const created = await ok.json<CreatedKey>();
    expect((await h.request(`/v1/vms/${b.vmId}`, bearer(created.key))).status).toBe(404);
  });

  it("needs the admin scope; every other scope is not enough", async () => {
    const key = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec", "vm:files", "vm:terminal", "snapshot:*"]);
    const response = await create(bearer(key), { name: "x", scopes: ["vm:read"] });
    expect(response.status).toBe(403);
    expect((await h.request("/v1/api-keys", bearer(key))).status).toBe(403);
  });

  it("allows a session of a team admin, including the admin scope, and refuses a plain member", async () => {
    h.addMember(TENANT_A, "user_admin");
    h.addAdmin(TENANT_A, "user_admin");
    h.addMember(TENANT_A, "user_member");
    const asAdmin = { ...bearer(await h.sessionToken("user_admin")), "x-cmux-team-id": TENANT_A };
    const asMember = { ...bearer(await h.sessionToken("user_member")), "x-cmux-team-id": TENANT_A };

    expect((await create(asAdmin, { name: "ops", scopes: ["admin", "vm:read"] })).status).toBe(201);
    expect((await create(asMember, { name: "nope", scopes: ["vm:read"] })).status).toBe(403);
    expect((await h.request("/v1/api-keys", asMember)).status).toBe(403);
  });

  it("caps a new key's expiry at an expiring issuer's: a missing or later expiry is refused with 400", async () => {
    const issuerExpiry = new Date(Date.now() + 60 * 60 * 1000);
    const admin = await h.addKey(TENANT_A, ["admin", "vm:read"], { expiresAt: issuerExpiry });
    const later = new Date(issuerExpiry.getTime() + 60 * 60 * 1000).toISOString();
    const sooner = new Date(issuerExpiry.getTime() - 30 * 60 * 1000).toISOString();

    expect((await create(bearer(admin), { name: "forever", scopes: ["vm:read"] })).status).toBe(400);
    expect((await create(bearer(admin), { name: "later", scopes: ["vm:read"], expiresAt: later })).status).toBe(400);
    const ok = await create(bearer(admin), { name: "sooner", scopes: ["vm:read"], expiresAt: sooner });
    expect(ok.status).toBe(201);
    expect(await ok.json<{ expiresAt: string | null }>()).toMatchObject({ expiresAt: sooner });
    expect(h.storedKeys().filter((key) => key.tenantId === TENANT_A)).toHaveLength(2);
  });

  it("lets a team admin's session and a non-expiring key set any expiry, or none", async () => {
    h.addMember(TENANT_A, "user_admin");
    h.addAdmin(TENANT_A, "user_admin");
    const asAdmin = { ...bearer(await h.sessionToken("user_admin")), "x-cmux-team-id": TENANT_A };
    const forever = await h.addKey(TENANT_A, ["admin", "vm:read"]);
    const far = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString();

    expect((await create(asAdmin, { name: "s1", scopes: ["vm:read"] })).status).toBe(201);
    expect((await create(asAdmin, { name: "s2", scopes: ["vm:read"], expiresAt: far })).status).toBe(201);
    expect((await create(bearer(forever), { name: "k1", scopes: ["vm:read"] })).status).toBe(201);
  });

  it("rejects an unknown scope and an empty scope list", async () => {
    const admin = await h.addKey(TENANT_A, ["admin", "vm:read"]);
    expect((await create(bearer(admin), { name: "x", scopes: ["vm:everything"] })).status).toBe(400);
    expect((await create(bearer(admin), { name: "x", scopes: [] })).status).toBe(400);
  });
});

describe("tenant isolation", () => {
  it("lists only the caller's tenant's keys", async () => {
    const adminA = await h.addKey(TENANT_A, ["admin"]);
    const adminB = await h.addKey(TENANT_B, ["admin"]);
    const a = await (await create(bearer(adminA), { name: "a", scopes: ["admin"] })).json<CreatedKey>();

    const listed = await (await h.request("/v1/api-keys", bearer(adminB))).json<{ items: Array<{ id: string }> }>();

    expect(listed.items.map((item) => item.id)).not.toContain(a.id);
  });

  it("answers 404 when tenant B revokes tenant A's key, and the key keeps working", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const adminA = await h.addKey(TENANT_A, ["admin", "vm:read"]);
    const adminB = await h.addKey(TENANT_B, ["admin", "vm:read"]);
    const a = await (await create(bearer(adminA), { name: "a", scopes: ["vm:read"] })).json<CreatedKey>();

    const response = await h.request(`/v1/api-keys/${a.id}`, bearer(adminB), { method: "DELETE" });

    expect(response.status).toBe(404);
    expect((await h.request(`/v1/vms/${vmId}`, bearer(a.key))).status).toBe(200);
  });
});

describe("revoke", () => {
  it("revokes the tenant's key, which then fails authentication, and audits it", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const admin = await h.addKey(TENANT_A, ["admin", "vm:read"]);
    const created = await (await create(bearer(admin), { name: "ci", scopes: ["vm:read"] })).json<CreatedKey>();

    const response = await h.request(`/v1/api-keys/${created.id}`, bearer(admin), { method: "DELETE" });

    expect(response.status).toBe(204);
    expect((await h.request(`/v1/vms/${vmId}`, bearer(created.key))).status).toBe(401);
    expect(h.audit.at(-1)).toMatchObject({ action: "apikey.revoke", cmuxId: created.id, outcome: "ok" });
  });

  it("gives the same 404 for a missing and a malformed key id", async () => {
    const admin = await h.addKey(TENANT_A, ["admin"]);
    const missing = await h.request("/v1/api-keys/vmk_00000000000000000000000000", bearer(admin), { method: "DELETE" });
    const malformed = await h.request("/v1/api-keys/not-a-key", bearer(admin), { method: "DELETE" });
    expect(missing.status).toBe(404);
    expect(malformed.status).toBe(404);
    expect(await missing.json()).toEqual(await malformed.json());
  });
});
