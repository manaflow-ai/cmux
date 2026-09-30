import { afterEach, describe, expect, test } from "bun:test";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import { sql } from "drizzle-orm";
import { PgDialect } from "drizzle-orm/pg-core";
import {
  CHATMUX_VM_AUTHORIZATION_HEADER,
  CHATMUX_VM_TOKEN_MAX_LIFETIME_SECONDS,
  chatmuxConfig,
  verifyChatmuxVmToken,
} from "../services/coderouter/chatmuxVmToken";
import { authenticateRequestRouteToken } from "../services/coderouter/routeTokenAuth";
import { resolveCoderouterControlContext } from "../services/coderouter/requestContext";
import { requireVmPrincipal } from "../services/vms/vmPrincipal";
import {
  accountAccessForIdentity,
  accountAccessPredicate,
  scopedSessionKey,
} from "../services/coderouter/accountAccess";

const ISSUER = "https://chatmux.dev";
const now = Math.floor(Date.now() / 1000);
/** The verifier's clock, pinned to the tokens' issue time. */
const at = new Date(now * 1000);
const signing = await generateKeyPair("ES256");
const other = await generateKeyPair("ES256");
const publicJwk = { ...(await exportJWK(signing.publicKey)), kid: "hsm-1", alg: "ES256", use: "sig" };
const config = { keys: createLocalJWKSet({ keys: [publicJwk] }), issuers: [ISSUER] };

const claims = { sub: "vm:vm-123", jti: "tok-1", team_id: "team-a", owner_id: "user-1", role: "dev" };
async function token(
  over: Record<string, unknown> = {},
  header: Record<string, unknown> = {},
  key = signing.privateKey,
) {
  return await new SignJWT({ iss: ISSUER, aud: ["coderouter", "chatmux"], iat: now, exp: now + 3600, ...claims, ...over })
    .setProtectedHeader({ alg: "ES256", kid: "hsm-1", typ: "JWT", ...header })
    .sign(key);
}

describe("chatmux VM tokens", () => {
  test("accepts a token signed by the chatmux key with the expected claims", async () => {
    expect(await verifyChatmuxVmToken(await token(), config, at)).toEqual({ ...claims, iss: ISSUER } as never);
  });

  test("rejects other keys, issuers, audiences, lifetimes, roles, and missing claims", async () => {
    const bad = [
      await token({}, {}, other.privateKey),
      await token({ iss: "https://evil.example" }),
      await token({ aud: "chatmux" }),
      await token({ exp: now - 120 }),
      await token({ iat: now - 10, exp: now - 10 + CHATMUX_VM_TOKEN_MAX_LIFETIME_SECONDS + 60 }),
      await token({ role: "admin" }),
      await token({ sub: "user-1" }),
      await token({ team_id: "" }),
      await token({ owner_id: undefined }),
      await token({ jti: undefined }),
      await token({}, { kid: "unknown" }),
      "a.b.c",
      "x".repeat(5000),
    ];
    for (const t of bad) expect(await verifyChatmuxVmToken(t, config, at)).toBe(null);
  });

  test("is off unless both a https JWKS address and issuers are configured", () => {
    expect(chatmuxConfig({})).toBe(null);
    expect(chatmuxConfig({ CODEROUTER_CHATMUX_JWKS_URL: "https://chatmux.dev/.well-known/chatmux-vm-jwks.json" })).toBe(null);
    expect(chatmuxConfig({ CODEROUTER_CHATMUX_JWKS_URL: "http://chatmux.dev/jwks", CODEROUTER_CHATMUX_ISSUERS: ISSUER })).toBe(null);
    expect(
      chatmuxConfig({
        CODEROUTER_CHATMUX_JWKS_URL: "https://chatmux.dev/.well-known/chatmux-vm-jwks.json",
        CODEROUTER_CHATMUX_ISSUERS: `${ISSUER}, https://preview.example`,
      })?.issuers,
    ).toEqual([ISSUER, "https://preview.example"]);
  });
});

describe("chatmux machines in request authentication", () => {
  const originalFetch = globalThis.fetch;
  const env = { ...process.env };
  afterEach(() => {
    globalThis.fetch = originalFetch;
    process.env = { ...env };
  });

  function serveJwks() {
    process.env.CODEROUTER_CHATMUX_JWKS_URL = "https://jwks.test/.well-known/chatmux-vm-jwks.json";
    process.env.CODEROUTER_CHATMUX_ISSUERS = ISSUER;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ keys: [publicJwk] }), {
        headers: { "content-type": "application/json" },
      })) as unknown as typeof fetch;
  }

  const request = (value: string, extra: Record<string, string> = {}) =>
    new Request("https://coderouter.test/v1/models", {
      headers: { [CHATMUX_VM_AUTHORIZATION_HEADER]: value, ...extra },
    });

  test("a valid token is the whole identity: no database lookup, team-shared access", async () => {
    serveJwks();
    let lookups = 0;
    const result = await authenticateRequestRouteToken(request(`Bearer ${await token()}`), async () => {
      lookups++;
      return null;
    });
    expect(lookups).toBe(0);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect([result.identity.teamId, result.identity.stackUserId, result.identity.vmId, result.identity.machine])
      .toEqual(["team-a", "user-1", "chatmux:vm-123", "chatmux"]);
    expect(accountAccessForIdentity(result.identity)).toEqual({
      kind: "team-machine",
      teamId: "team-a",
      machineId: "chatmux:vm-123",
    });
  });

  test("a bad chatmux token fails closed and never falls back to another credential", async () => {
    serveJwks();
    for (const value of ["", "Bearer", "Basic x", `Bearer ${await token({}, {}, other.privateKey)}`]) {
      let lookups = 0;
      const result = await authenticateRequestRouteToken(
        request(value, { authorization: "Bearer crt_valid_cli", "x-coderouter-route-token": "crt_valid_cli" }),
        async () => {
          lookups++;
          return { teamId: "t", stackUserId: "u" };
        },
      );
      expect(result).toEqual({ ok: false, reason: "invalid_route_token" });
      expect(lookups).toBe(0);
    }
  });

  test("a chatmux machine cannot manage accounts, even with a route-token header added", async () => {
    serveJwks();
    const resolved = await resolveCoderouterControlContext(
      request(`Bearer ${await token()}`, { "x-coderouter-route-token": "crt_anything" }),
    );
    expect(resolved.ok).toBe(false);
    if (resolved.ok) return;
    expect(resolved.response.status).toBe(403);
    expect(await resolved.response.json()).toEqual({ error: "chatmux_machine_not_allowed" });
  });

  test("a chatmux machine is not a Cloud VM principal", async () => {
    serveJwks();
    let loads = 0;
    const result = await requireVmPrincipal(request(`Bearer ${await token()}`), {
      loadVm: async () => {
        loads++;
        return null;
      },
    });
    expect(result).toEqual({ ok: false, reason: "vm_bound_token_required" });
    expect(loads).toBe(0);
  });
});

describe("team-machine account access", () => {
  const dialect = new PgDialect();
  const account = { id: sql`a.id`, teamId: sql`a.team_id`, visibility: sql`a.visibility`, createdBy: sql`a.created_by` };

  test("allows only accounts its team shares, never a private account", () => {
    const q = dialect.sqlToQuery(
      accountAccessPredicate(account, "native", { kind: "team-machine", teamId: "team-a", machineId: "m" }),
    );
    expect(q.sql).toBe("(a.visibility = 'team' and a.team_id = $1)");
    expect(q.params).toEqual(["team-a"]);
  });

  test("an empty team id matches nothing", () => {
    const q = dialect.sqlToQuery(
      accountAccessPredicate(account, "native", { kind: "team-machine", teamId: "", machineId: "m" }),
    );
    expect(q.sql).toBe("false");
  });

  test("session keys of different machines never collide", () => {
    const a = scopedSessionKey("k", { kind: "team-machine", teamId: "t", machineId: "chatmux:vm-1" });
    const b = scopedSessionKey("k", { kind: "team-machine", teamId: "t", machineId: "chatmux:vm-2" });
    expect(a).not.toBe(b);
    expect(a).toBe(JSON.stringify(["team-machine", "chatmux:vm-1", "k"]));
  });
});
