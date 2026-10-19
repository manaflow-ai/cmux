import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { exportJWK, generateKeyPair } from "jose";
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
  it("requires the issuer's matching VM scope for each delegated scope", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create"]);
    const response = await h.request("/v1/access-tokens", bearer(key), { method: "POST", body: { principal: "end_user_1", vmIds: [vmId], scopes: ["exec"] } });
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ missingScope: "vm:exec" });
  });

  it("mints once, brokers exec and files, and refuses management and lifecycle calls", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create", "vm:exec", "vm:files"]);
    const created = await mint(key, vmId, ["exec", "files:read", "files:write"]);
    expect(created.token).toMatch(/^cmux_at_/u);
    const management = await json(await h.request("/v1/access-tokens", bearer(created.token)));
    expect(typeof management === "object" && management !== null && "_tag" in management ? management._tag : undefined).toBe("Forbidden");
    expect((await h.request(`/v1/vms/${vmId}/pause`, bearer(created.token), { method: "POST" })).status).toBe(403);
    expect((await h.request("/v1/vms", bearer(created.token), { method: "POST", body: {} })).status).toBe(403);
    expect((await h.request(`/v1/vms/${vmId}`, bearer(created.token), { method: "DELETE" })).status).toBe(403);
    expect(await (await h.request(`/v1/vms/${vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "id -u" } })).json()).toMatchObject({ exitCode: 0 });
    const write = await h.send(`/v1/vms/${vmId}/files/content?path=%2Ftmp%2Ftoken.txt`, bearer(created.token), "PUT", new TextEncoder().encode("secret"));
    expect(write.status).toBe(204);
    expect(h.upstream.callsTo("PUT", /fs\/write$/u).at(-1)?.search.get("linuxUser")).toBe("cmux");
    const read = await h.request(`/v1/vms/${vmId}/files/content?path=%2Ftmp%2Ftoken.txt`, bearer(created.token));
    expect(await read.text()).toBe("secret");
  });

  it("opens a PTY only on an allowed VM and forces the token Linux user", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create", "vm:terminal"]);
    const created = await mint(key, vmId, ["pty"]);
    h.s3a.onTerminal((socket) => socket.close(1000, "done"));
    const response = await h.request(`/v1/vms/${vmId}/terminal?user=root`, { ...bearer(created.token), upgrade: "websocket" });
    expect(response.status).toBe(101);
    const call = h.s3a.requests.at(-1);
    expect(call === undefined ? null : new URL(call.url).searchParams.get("linuxUser")).toBe("cmux");
    response.webSocket?.close();
  });

  it("returns 404 for another VM or tenant and 403 for a missing operation scope", async () => {
    const own = h.addVm(TENANT_A);
    const other = h.addVm(TENANT_A);
    const foreign = h.addVm(TENANT_B);
    const key = await h.addKey(TENANT_A, ["access-token:create", "vm:exec"]);
    const created = await mint(key, own.vmId, ["exec"]);
    expect((await h.request(`/v1/vms/${other.vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "true" } })).status).toBe(404);
    expect((await h.request(`/v1/vms/${foreign.vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "true" } })).status).toBe(404);
    expect((await h.request(`/v1/vms/${own.vmId}/files/content?path=%2Ftmp%2Fx`, bearer(created.token))).status).toBe(403);
  });

  it("revokes immediately and rejects expiry and forged signatures", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create", "vm:exec"]);
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

  it("accepts an old signing kid during rotation and rejects a tampered VM claim", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create", "vm:exec"]);
    const created = await mint(key, vmId, ["exec"]);
    const oldKeys = h.accessTokenKeys();
    const oldKey = oldKeys[0];
    if (oldKey === undefined) throw new Error("default access-token key missing");
    const { publicKey, privateKey } = await generateKeyPair("Ed25519", { extractable: true });
    const nextKey = { kid: "access-next", privateJwk: { ...(await exportJWK(privateKey)), alg: "EdDSA", kid: "access-next" }, publicJwk: { ...(await exportJWK(publicKey)), alg: "EdDSA", kid: "access-next" }, active: true };
    const nextKeys = [
      { ...oldKey, active: false },
      nextKey,
    ];
    h.setAccessTokenKeys(nextKeys);
    expect((await h.request(`/v1/vms/${vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "true" } })).status).toBe(200);
    h.setAccessTokenKeys([nextKey]);
    expect((await h.request(`/v1/vms/${vmId}/exec`, bearer(created.token), { method: "POST", body: { command: "true" } })).status).toBe(401);

    const fresh = await mint(key, vmId, ["exec"]);
    const compact = fresh.token.slice("cmux_at_".length).split(".");
    if (compact.length !== 3 || compact[1] === undefined || compact[2] === undefined) throw new Error("token compact form invalid");
    const payload = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(compact[1].replaceAll("-", "+").replaceAll("_", "/")), (character) => character.charCodeAt(0))));
    if (typeof payload !== "object" || payload === null || !("vmIds" in payload)) throw new Error("token payload missing vmIds");
    payload.vmIds = ["vm_00000000000000000000000000"];
    const encoded = btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(payload)))).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
    const tampered = `cmux_at_${compact[0]}.${encoded}.${compact[2]}`;
    expect((await h.request(`/v1/vms/${vmId}/exec`, bearer(tampered), { method: "POST", body: { command: "true" } })).status).toBe(401);
  });

  it("mints and revokes a delegated Freestyle SSH identity", async () => {
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create", "vm:read"]);
    const created = await mint(key, vmId, ["ssh"]);
    const ssh = await json(await h.request(`/v1/access-tokens/${created.id}/ssh`, bearer(created.token), { method: "POST" }));
    expect(ssh).toMatchObject({ host: "beta-ssh.freestyle.sh", user: `${upstreamId}+cmux` });
    const sshAgain = await json(await h.request(`/v1/access-tokens/${created.id}/ssh`, bearer(created.token), { method: "POST" }));
    expect(sshAgain).toMatchObject({ host: "beta-ssh.freestyle.sh", user: `${upstreamId}+cmux` });
    expect(h.upstream.callsTo("POST", /\/identities$/u)).toHaveLength(1);
    expect((await h.request(`/v1/access-tokens/${created.id}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    expect(h.upstream.identities.size).toBe(0);
  });

  it("denies a token before the database revoke when provider identity cleanup fails", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["access-token:create", "vm:read"]);
    const created = await mint(key, vmId, ["ssh"]);
    await h.request(`/v1/access-tokens/${created.id}/ssh`, bearer(created.token), { method: "POST" });
    h.upstream.fail("deleteIdentity", 503);
    expect((await h.request(`/v1/access-tokens/${created.id}`, bearer(key), { method: "DELETE" })).status).toBe(503);
    expect((await h.request(`/v1/access-tokens/${created.id}/ssh`, bearer(created.token), { method: "POST" })).status).toBe(401);
  });
});
