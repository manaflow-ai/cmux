import { afterAll, describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { authenticateRequestRouteToken } from "../services/coderouter/routeTokenAuth";
import { signVmAuthorization } from "../services/coderouter/vmAuthorization";

const previousKey = process.env.CMUX_VM_AUTH_SIGNING_KEY;
const previousKid = process.env.CMUX_VM_AUTH_SIGNING_KEY_ID;
process.env.CMUX_VM_AUTH_SIGNING_KEY = randomBytes(32).toString("base64url");
process.env.CMUX_VM_AUTH_SIGNING_KEY_ID = "test-v1";

afterAll(() => {
  if (previousKey === undefined) delete process.env.CMUX_VM_AUTH_SIGNING_KEY;
  else process.env.CMUX_VM_AUTH_SIGNING_KEY = previousKey;
  if (previousKid === undefined) delete process.env.CMUX_VM_AUTH_SIGNING_KEY_ID;
  else process.env.CMUX_VM_AUTH_SIGNING_KEY_ID = previousKid;
});

function request(token: string): Request {
  return new Request("https://coderouter.dev/v1/models", {
    headers: { "x-cmux-authorization": `Bearer ${token}` },
  });
}

describe("signed VM authorization", () => {
  test("accepts a valid claim and derives the VM binding without a VM header", async () => {
    const token = await signVmAuthorization({
      vmId: "vm-a",
      teamId: "team-a",
      ownerId: "user-a",
      expiresAt: new Date(Date.now() + 60_000),
    });
    await expect(authenticateRequestRouteToken(request(token), async () => ({
      teamId: "team-a", stackUserId: "user-a", vmId: "vm-a",
    }))).resolves.toMatchObject({
      ok: true,
      identity: { teamId: "team-a", stackUserId: "user-a", vmId: "vm-a" },
    });
  });

  test("rejects expired, wrong-owner, and wrong-VM claims", async () => {
    const expired = await signVmAuthorization({
      vmId: "vm-a", teamId: "team-a", ownerId: "user-a", expiresAt: new Date(Date.now() - 10_000),
    });
    expect(await authenticateRequestRouteToken(request(expired), async () => ({
      teamId: "team-a", stackUserId: "user-a", vmId: "vm-a",
    }))).toEqual({ ok: false, reason: "invalid_route_token" });

    const wrongClaims = await signVmAuthorization({
      vmId: "vm-b", teamId: "team-b", ownerId: "user-b", expiresAt: new Date(Date.now() + 60_000),
    });
    expect(await authenticateRequestRouteToken(request(wrongClaims), async () => ({
      teamId: "team-a", stackUserId: "user-a", vmId: "vm-a",
    }))).toEqual({ ok: false, reason: "vm_mismatch" });
  });

  test("accepts a previous key during rotation when the key id is retained", async () => {
    const oldKey = randomBytes(32).toString("base64url");
    const newKey = randomBytes(32).toString("base64url");
    process.env.CMUX_VM_AUTH_SIGNING_KEY = oldKey;
    process.env.CMUX_VM_AUTH_SIGNING_KEY_ID = "old";
    const token = await signVmAuthorization({
      vmId: "vm-a", teamId: "team-a", ownerId: "user-a", expiresAt: new Date(Date.now() + 60_000),
    });
    process.env.CMUX_VM_AUTH_SIGNING_KEY = newKey;
    process.env.CMUX_VM_AUTH_SIGNING_KEY_ID = "new";
    process.env.CMUX_VM_AUTH_SIGNING_PREVIOUS_KEYS = JSON.stringify({ old: oldKey });
    await expect(authenticateRequestRouteToken(request(token), async () => ({
      teamId: "team-a", stackUserId: "user-a", vmId: "vm-a",
    }))).resolves.toMatchObject({ ok: true });
    delete process.env.CMUX_VM_AUTH_SIGNING_PREVIOUS_KEYS;
  });
});
