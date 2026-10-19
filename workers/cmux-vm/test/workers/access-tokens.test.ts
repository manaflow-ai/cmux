import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h?.dispose();
});

const json = async (response: Response): Promise<unknown> => response.json();

interface CreatedTokenBody {
  readonly id: string;
  readonly token: string;
}

const mint = async (key: string, vmId: string, scopes: string[], ttlSeconds = 3600) =>
  (async () => {
    const body = await json(await h.request("/v1/access-tokens", bearer(key), { method: "POST", body: { principal: "end_user_1", vmIds: [vmId], scopes, ttlSeconds } }));
    if (typeof body === "object" && body !== null && "id" in body && "token" in body && typeof body.id === "string" && typeof body.token === "string") return { id: body.id, token: body.token } satisfies CreatedTokenBody;
    throw new Error("access token response was malformed");
  })();

describe("access tokens", () => {
  it("mints once, brokers exec and files, and refuses management and lifecycle calls", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create"]);
    const created = await mint(key, vmId, ["exec", "files:read", "files:write"]);
    expect(created.token).toMatch(/^cmux_at_/u);
    const management = await json(await h.request("/v1/access-tokens", bearer(created.token)));
    expect(typeof management === "object" && management !== null && "_tag" in management ? management._tag : undefined).toBe("Forbidden");
    expect((await h.request(`/v1/vms/${vmId}/pause`, bearer(created.token), { method: "POST" })).status).toBe(403);
    expect(await (await h.request(`/v1/vms/${vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "id -u" } })).json()).toMatchObject({ exitCode: 0 });
    const write = await h.send(`/v1/vms/${vmId}/files/content?path=%2Ftmp%2Ftoken.txt`, bearer(created.token), "PUT", new TextEncoder().encode("secret"));
    expect(write.status).toBe(204);
    const read = await h.request(`/v1/vms/${vmId}/files/content?path=%2Ftmp%2Ftoken.txt`, bearer(created.token));
    expect(await read.text()).toBe("secret");
  });

  it("returns 404 for another VM or tenant and 403 for a missing operation scope", async () => {
    const own = h.addVm(TENANT_A);
    const other = h.addVm(TENANT_A);
    const foreign = h.addVm(TENANT_B);
    const key = await h.addKey(TENANT_A, ["access-token:create"]);
    const created = await mint(key, own.vmId, ["exec"]);
    expect((await h.request(`/v1/vms/${other.vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "true" } })).status).toBe(404);
    expect((await h.request(`/v1/vms/${foreign.vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "true" } })).status).toBe(404);
    expect((await h.request(`/v1/vms/${own.vmId}/files/content?path=%2Ftmp%2Fx`, bearer(created.token))).status).toBe(403);
  });

  it("revokes immediately and rejects expiry and forged signatures", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create"]);
    const created = await mint(key, vmId, ["exec"], 1);
    const id = created.id;
    expect((await h.request(`/v1/access-tokens/${id}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    expect((await h.request(`/v1/vms/${vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "true" } })).status).toBe(401);
    const fresh = await mint(key, vmId, ["exec"]);
    const forged = `${fresh.token.slice(0, -1)}${fresh.token.endsWith("A") ? "B" : "A"}`;
    expect((await h.request(`/v1/vms/${vmId}/exec`, bearer(forged), { method: "POST", body: { command: "true" } })).status).toBe(401);
    await new Promise((resolve) => setTimeout(resolve, 1100));
    expect((await h.request(`/v1/vms/${vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "true" } })).status).toBe(401);
  });

  it("mints and revokes a delegated Freestyle SSH identity", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create"]);
    const created = await mint(key, vmId, ["ssh"]);
    const ssh = await json(await h.request(`/v1/access-tokens/${created.id}/ssh`, bearer(key), { method: "POST" }));
    expect(ssh).toMatchObject({ host: "beta-ssh.freestyle.sh", user: `${vmId}+cmux` });
    expect(h.upstream.callsTo("POST", /\/identities$/u)).toHaveLength(1);
    expect((await h.request(`/v1/access-tokens/${created.id}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    expect(h.upstream.identities.size).toBe(0);
  });
});
