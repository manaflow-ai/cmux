import { describe, expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  handleStackWebhook,
  parseStackWebhookEvent,
  verifySvixSignature,
  type StackWebhookDependencies,
} from "../services/auth/stackWebhook";
import { VmProviderOperationError } from "../services/vms/errors";
import { networkSlugForTeam } from "../services/vms/privateNetwork";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { revokeTeamNetworkAccess } from "../services/vms/teamNetworkAccess";
import { revokeTeamAccess, revokeTeamMemberAccess, type TeamRevocationDependencies } from "../services/vms/teamMemberRevocation";

const KEY = Buffer.from("stack-webhook-test-key-0123456789");
const SECRET = `whsec_${KEY.toString("base64")}`;
const NOW = 1_800_000_000;

function sign(id: string, timestamp: number, body: string, key = KEY): string {
  return createHmac("sha256", key).update(`${id}.${timestamp}.${body}`).digest("base64");
}

function signedHeaders(body: string, options: { timestamp?: number; signature?: string } = {}): Headers {
  const timestamp = options.timestamp ?? NOW;
  return new Headers({
    "content-type": "application/json",
    "svix-id": "msg_1",
    "svix-timestamp": String(timestamp),
    "svix-signature": options.signature ?? `v1,${sign("msg_1", timestamp, body)}`,
  });
}

describe("Svix signature verification", () => {
  const body = JSON.stringify({ type: "team_membership.deleted", data: { team_id: "team-1", user_id: "user-1" } });

  test("accepts a valid signature", () => {
    expect(verifySvixSignature({ secret: SECRET, headers: signedHeaders(body), rawBody: body, nowSeconds: NOW })).toEqual({ ok: true });
  });

  test("accepts any matching entry in a rotated signature list", () => {
    const signature = `v1,${sign("msg_1", NOW, body, Buffer.from("old-key"))} v1,${sign("msg_1", NOW, body)}`;
    expect(verifySvixSignature({ secret: SECRET, headers: signedHeaders(body, { signature }), rawBody: body, nowSeconds: NOW }).ok).toBe(true);
  });

  test("rejects a bad signature and a tampered body", () => {
    const bad = signedHeaders(body, { signature: `v1,${Buffer.alloc(32).toString("base64")}` });
    expect(verifySvixSignature({ secret: SECRET, headers: bad, rawBody: body, nowSeconds: NOW })).toEqual({ ok: false, reason: "bad_signature" });
    expect(verifySvixSignature({ secret: SECRET, headers: signedHeaders(body), rawBody: `${body} `, nowSeconds: NOW })).toEqual({ ok: false, reason: "bad_signature" });
    const wrongVersion = signedHeaders(body, { signature: `v2,${sign("msg_1", NOW, body)}` });
    expect(verifySvixSignature({ secret: SECRET, headers: wrongVersion, rawBody: body, nowSeconds: NOW }).ok).toBe(false);
  });

  test("rejects timestamps outside five minutes either way", () => {
    for (const timestamp of [NOW - 301, NOW + 301]) {
      expect(verifySvixSignature({ secret: SECRET, headers: signedHeaders(body, { timestamp }), rawBody: body, nowSeconds: NOW }))
        .toEqual({ ok: false, reason: "stale_timestamp" });
    }
    expect(verifySvixSignature({ secret: SECRET, headers: signedHeaders(body, { timestamp: NOW - 299 }), rawBody: body, nowSeconds: NOW }).ok).toBe(true);
  });

  test("rejects missing headers", () => {
    const headers = signedHeaders(body);
    headers.delete("svix-signature");
    expect(verifySvixSignature({ secret: SECRET, headers, rawBody: body, nowSeconds: NOW })).toEqual({ ok: false, reason: "missing_headers" });
  });
});

describe("Stack webhook dispatch", () => {
  function harness(overrides: Partial<StackWebhookDependencies> = {}) {
    const calls: string[] = [];
    const dependencies: StackWebhookDependencies = {
      webhookSecret: () => SECRET,
      nowSeconds: () => NOW,
      revokeTeamMemberAccess: async ({ teamId, userId }) => { calls.push(`member:${teamId}:${userId}`); },
      revokeTeamAccess: async ({ teamId }) => { calls.push(`team:${teamId}`); },
      logError: () => {},
      ...overrides,
    };
    const post = (payload: unknown, headers?: Headers) => {
      const body = JSON.stringify(payload);
      return handleStackWebhook(new Request("https://cmux.test/api/webhooks/stack", {
        method: "POST", headers: headers ?? signedHeaders(body), body,
      }), dependencies);
    };
    return { calls, post };
  }

  test("missing secret answers 503 and processes nothing", async () => {
    const { calls, post } = harness({ webhookSecret: () => undefined });
    const response = await post({ type: "team_membership.deleted", data: { team_id: "team-1", user_id: "user-1" } });
    expect(response.status).toBe(503);
    expect(calls).toEqual([]);
  });

  test("an unsigned request answers 401 and processes nothing", async () => {
    const { calls, post } = harness();
    const response = await post(
      { type: "team_membership.deleted", data: { team_id: "team-1", user_id: "user-1" } },
      new Headers({ "svix-id": "msg_1", "svix-timestamp": String(NOW), "svix-signature": "v1,AAAA" }),
    );
    expect(response.status).toBe(401);
    expect(calls).toEqual([]);
  });

  test("team_membership.deleted revokes that member's access to that team", async () => {
    const { calls, post } = harness();
    const response = await post({ type: "team_membership.deleted", data: { team_id: "team-1", user_id: "user-1" } });
    expect(response.status).toBe(200);
    expect(calls).toEqual(["member:team-1:user-1"]);
  });

  test("team.deleted revokes every tunnel on the team network", async () => {
    const { calls, post } = harness();
    expect((await post({ type: "team.deleted", data: { id: "team-9" } })).status).toBe(200);
    expect(calls).toEqual(["team:team-9"]);
  });

  test("other events are acknowledged and ignored; malformed membership events are 400", async () => {
    const { calls, post } = harness();
    expect((await post({ type: "user.updated", data: { id: "user-1" } })).status).toBe(200);
    expect((await post({ type: "team_membership.deleted", data: { team_id: "team-1" } })).status).toBe(400);
    expect(calls).toEqual([]);
    expect(parseStackWebhookEvent("not json")).toEqual({ type: "malformed" });
  });

  test("a failed revocation answers 500 so Svix retries", async () => {
    const { post } = harness({ revokeTeamMemberAccess: async () => { throw new Error("provider down"); } });
    const response = await post({ type: "team_membership.deleted", data: { team_id: "team-1", user_id: "user-1" } });
    expect(response.status).toBe(500);
  });
});

describe("team network revocation", () => {
  type Row = { readonly providerTunnelId: string; readonly userId: string; readonly revokedAt: Date | null };
  const networks: Record<string, readonly string[]> = {
    [networkSlugForTeam("team-1")]: ["tun-removed-mac", "tun-removed-browser", "tun-other-member", "tun-unknown"],
    [networkSlugForTeam("team-2")]: ["tun-removed-team-2"],
  };
  const rows: readonly Row[] = [
    { providerTunnelId: "tun-removed-mac", userId: "removed", revokedAt: null },
    { providerTunnelId: "tun-removed-browser", userId: "removed", revokedAt: null },
    { providerTunnelId: "tun-other-member", userId: "member", revokedAt: null },
    { providerTunnelId: "tun-removed-team-2", userId: "removed", revokedAt: null },
  ];

  function run(input: { teamId: string; userId?: string }, options: { failDetach?: string } = {}) {
    const detached: string[] = [];
    const repo = {
      findTunnelsByProviderTunnelIds: (_provider: string, ids: readonly string[]) =>
        Effect.succeed(rows.filter((row) => ids.includes(row.providerTunnelId))),
    } as unknown as VmRepositoryShape;
    const gateway = {
      supportsPrivateNetworking: () => true,
      getNetwork: (_provider: string, slug: string) =>
        Effect.succeed(networks[slug] ? { id: `vpc:${slug}`, slug, cidr: "10.60.0.0/24", cidrV6: null } : null),
      listNetworkTunnelIds: (_provider: string, networkId: string) =>
        Effect.succeed([...(networks[networkId.replace(/^vpc:/, "")] ?? [])]),
      detachTunnelNetwork: (_provider: string, tunnelId: string, networkId: string) => tunnelId === options.failDetach
        ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "detachTunnelNetwork", cause: new Error("down") }))
        : Effect.sync(() => { detached.push(`${tunnelId}@${networkId}`); }),
    } as unknown as VmProviderGatewayShape;
    const effect = revokeTeamNetworkAccess(input).pipe(
      Effect.provide(Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, gateway))),
    );
    return { detached, result: Effect.runPromise(Effect.either(effect)) };
  }

  test("detaches only the removed member's tunnels, only from that team's network", async () => {
    const { detached, result } = run({ teamId: "team-1", userId: "removed" });
    const outcome = await result;
    expect(outcome._tag).toBe("Right");
    const slug = networkSlugForTeam("team-1");
    expect(detached).toEqual([`tun-removed-mac@vpc:${slug}`, `tun-removed-browser@vpc:${slug}`]);
  });

  test("team deletion detaches every known tunnel and leaves unknown tunnels alone", async () => {
    const { detached, result } = run({ teamId: "team-1" });
    expect((await result)._tag).toBe("Right");
    expect(detached.map((entry) => entry.split("@")[0])).toEqual(["tun-removed-mac", "tun-removed-browser", "tun-other-member"]);
  });

  test("a team with no network is a no-op", async () => {
    const { detached, result } = run({ teamId: "team-none", userId: "removed" });
    expect((await result)._tag).toBe("Right");
    expect(detached).toEqual([]);
  });

  test("a failed detach still attempts the rest, then fails so the caller retries", async () => {
    const { detached, result } = run({ teamId: "team-1", userId: "removed" }, { failDetach: "tun-removed-mac" });
    const outcome = await result;
    expect(outcome._tag).toBe("Left");
    expect(detached).toEqual([`tun-removed-browser@vpc:${networkSlugForTeam("team-1")}`]);
  });
});

describe("revokeTeamMemberAccess", () => {
  function dependencies(overrides: Partial<TeamRevocationDependencies> = {}) {
    const calls: string[] = [];
    const deps: TeamRevocationDependencies = {
      revokeNetworkAccess: async ({ teamId, userId }) => { calls.push(`network:${teamId}:${userId ?? "*"}`); return { detached: 2 }; },
      deleteIdentitySnapshot: async (userId) => { calls.push(`snapshot:${userId}`); },
      invalidateAuthCache: (userId) => { calls.push(`cache:${userId}`); },
      ...overrides,
    };
    return { calls, deps };
  }

  test("detaches the team network and deletes the identity snapshot", async () => {
    const { calls, deps } = dependencies();
    expect(await revokeTeamMemberAccess({ teamId: "team-1", userId: "user-1" }, deps)).toEqual({ detached: 2 });
    expect(calls.sort()).toEqual(["cache:user-1", "network:team-1:user-1", "snapshot:user-1"]);
  });

  test("a failed snapshot delete still detaches, then throws for retry", async () => {
    const { calls, deps } = dependencies({ deleteIdentitySnapshot: async () => { throw new Error("db down"); } });
    await expect(revokeTeamMemberAccess({ teamId: "team-1", userId: "user-1" }, deps)).rejects.toThrow("db down");
    expect(calls).toContain("network:team-1:user-1");
  });

  test("a failed detach still deletes the snapshot, then throws for retry", async () => {
    const { calls, deps } = dependencies({ revokeNetworkAccess: async () => { throw new Error("provider down"); } });
    await expect(revokeTeamMemberAccess({ teamId: "team-1", userId: "user-1" }, deps)).rejects.toThrow("provider down");
    expect(calls).toContain("snapshot:user-1");
  });

  test("team deletion revokes the whole network", async () => {
    const { calls, deps } = dependencies();
    await revokeTeamAccess({ teamId: "team-1" }, deps);
    expect(calls).toEqual(["network:team-1:*"]);
  });
});
