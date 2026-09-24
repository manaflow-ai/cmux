import { describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { SignJWT } from "jose";
import { vmToken } from "./vm-authorization-fixture";
import { authenticateRequestRouteToken } from "../services/coderouter/routeTokenAuth";
import { verifyVmAuthorization, VM_AUTHORIZATION_LIFETIME_SECONDS } from "../services/coderouter/vmAuthorization";
import { renderVmGuestModelPlaneEnvFile } from "../services/coderouter/vmGuestEnv";
import { scrubSentryEvent } from "../services/sentry";

const identity = { teamId: "team-1", stackUserId: "user-1", vmId: "vm-1" };
const request = (token: string) => new Request("https://coderouter.test/v1/models", {
  headers: { "x-cmux-authorization": `Bearer ${token}` },
});
const now = Math.floor(Date.now() / 1000);
async function arbitraryToken(claims: Record<string, unknown> = {}, header: Record<string, unknown> = {}) {
  return await new SignJWT({ vm_id: "vm-1", team_id: "team-1", owner_id: "user-1", jti: "id-1",
    iss: "cmux", aud: "cmux-vm-model-plane", iat: now, exp: now + 60, ...claims })
    .setProtectedHeader({ alg: "HS256", typ: "cmux-vm+jwt", kid: "test-v1", ...header })
    .sign(Buffer.from(process.env.CMUX_VM_AUTH_SIGNING_KEY!, "base64url"));
}

describe("signed VM authorization", () => {
  test("derives VM identity from the signed claim without any VM header", async () => {
    const token = await vmToken();
    const req = request(token);
    req.headers.set("authorization", "Bearer crt_forged");
    req.headers.set("x-coderouter-route-token", "crt_forged");
    req.headers.set("x-cmux-vm-id", "vm-b");
    const result = await authenticateRequestRouteToken(req, async t => t === token ? identity : null);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.identity.vmId).toBe("vm-1");
  });

  test("malformed/unsigned headers fail closed without fallback or database access", async () => {
    for (const header of ["", "Basic abc", "Bearer", "Bearer crt_unsigned", "Bearer a.b.", "Bearer a.b.c, a.b.c", "a.b.c", `Bearer ${"x".repeat(4097)}`]) {
      const req = request("unused");
      req.headers.set("x-cmux-authorization", header);
      req.headers.set("authorization", "Bearer crt_valid_cli");
      let lookups = 0;
      const result = await authenticateRequestRouteToken(req, async () => { lookups++; return identity; });
      expect(result.ok).toBe(false);
      expect(lookups).toBe(0);
    }
  });

  test("rejects invalid signature, audience, type, key version, and time claims before lookup", async () => {
    const valid = await vmToken();
    const tokens = [
      valid.slice(0, valid.lastIndexOf(".") + 1) + "A".repeat(43),
      await arbitraryToken({ aud: "other" }), await arbitraryToken({ iss: "other" }),
      await arbitraryToken({ exp: now - 1 }), await arbitraryToken({ iat: now + 60 }),
      await arbitraryToken({ exp: now + VM_AUTHORIZATION_LIFETIME_SECONDS + 1 }),
      await arbitraryToken({ iat: null }), await arbitraryToken({ exp: null }),
      await arbitraryToken({ vm_id: "" }), await arbitraryToken({ team_id: null }),
      await arbitraryToken({ owner_id: [] }), await arbitraryToken({ jti: "" }),
      await arbitraryToken({}, { typ: "JWT" }), await arbitraryToken({}, { kid: "unknown" }),
      await arbitraryToken({}, { kid: "__proto__" }), await arbitraryToken({}, { alg: "HS384" }),
    ];
    for (const token of tokens) {
      let lookups = 0;
      expect((await authenticateRequestRouteToken(request(token), async () => { lookups++; return identity; })).ok).toBe(false);
      expect(lookups).toBe(0);
    }
  });

  test("a VM A token cannot authorize a VM B or different-owner database row", async () => {
    const token = await vmToken();
    for (const row of [{ ...identity, vmId: "vm-b" }, { ...identity, teamId: "team-b" }, { ...identity, stackUserId: "user-b" }]) {
      expect((await authenticateRequestRouteToken(request(token), async () => row)).ok).toBe(false);
    }
    expect((await authenticateRequestRouteToken(request(token), async () => null)).ok).toBe(false);
  });

  test("retiring a key rejects its tokens immediately, overlap permits only listed keys", async () => {
    const oldKey = process.env.CMUX_VM_AUTH_SIGNING_KEY!;
    const token = await vmToken();
    try {
      process.env.CMUX_VM_AUTH_SIGNING_KEY = randomBytes(32).toString("base64url");
      process.env.CMUX_VM_AUTH_SIGNING_KEY_ID = "test-v2";
      expect(await verifyVmAuthorization(token)).toBeNull();
      process.env.CMUX_VM_AUTH_SIGNING_PREVIOUS_KEYS = JSON.stringify({ "test-v1": oldKey });
      expect((await verifyVmAuthorization(token))?.vm_id).toBe("vm-1");
      delete process.env.CMUX_VM_AUTH_SIGNING_PREVIOUS_KEYS;
      expect(await verifyVmAuthorization(token)).toBeNull();
    } finally {
      process.env.CMUX_VM_AUTH_SIGNING_KEY = oldKey;
      process.env.CMUX_VM_AUTH_SIGNING_KEY_ID = "test-v1";
      delete process.env.CMUX_VM_AUTH_SIGNING_PREVIOUS_KEYS;
    }
  });

  test("secrets cannot enter guest environment files or telemetry", async () => {
    const token = await vmToken();
    expect(() => renderVmGuestModelPlaneEnvFile({ OPENAI_API_KEY: token })).toThrow();
    const event = scrubSentryEvent({ extra: { "x-cmux-authorization": `Bearer ${token}`, detail: token } });
    expect(JSON.stringify(event).includes(token)).toBe(false);
  });
});
