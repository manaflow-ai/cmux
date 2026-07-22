import { describe, expect, test } from "bun:test";
import {
  generateKeyPairSync,
  verify as edVerify,
} from "node:crypto";

import {
  handleRelayTokenRequest,
  type RelayTokenDeps,
} from "../app/api/relay/token/route";
import type { RelayPolicyPayload } from "../services/relay/model";
import { mintManagedRelayCredentials } from "../services/relay/token";
import type { AuthedUser } from "../services/vms/auth";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const ENDPOINT_ID = "0123456789abcdef".repeat(4);
const PAYLOAD: RelayPolicyPayload = {
  version: 1,
  jti: "01890f47-9ff8-7cc2-98b3-2fefdbb4312c",
  sequence: 4,
  iat: 1_700_000_000,
  nbf: 1_700_000_000,
  exp: 1_700_000_300,
  aud: "cmux-iroh-relay-policy",
  relay_protocol: "iroh-relay-v1",
  relays: [{
    id: "managed-one",
    provider: "cmux",
    region: "us-west",
    url: "https://relay-one.cmux.dev/",
  }],
};

function deps(overrides: Partial<RelayTokenDeps> = {}): RelayTokenDeps {
  return {
    verifyRequest: async () => ({ id: "account-a" }) as AuthedUser,
    signingKey: () => privateKey,
    nowSeconds: () => 1_700_000_000,
    signedPolicy: async (accountId) => {
      expect(accountId).toBe("account-a");
      return {
        policy: "signed.policy.value",
        payload: PAYLOAD,
        preference: {
          mode: "managed",
          selectedManagedRelayIds: ["managed-one"],
          customRelays: [],
        },
        preferenceRevision: 3,
      };
    },
    issueCredentials: (input) => mintManagedRelayCredentials({
      sub: input.accountId,
      endpointId: input.endpointId,
      relayUrls: input.relayUrls,
      key: input.key,
      nowSeconds: input.nowSeconds,
    }),
    isEndpointBound: async () => true,
    checkRateLimit: async () => ({ rateLimited: false }),
    rateLimitRuleId: () => undefined,
    isVercel: () => false,
    ...overrides,
  };
}

function request(body: unknown): Request {
  return new Request("https://cmux.dev/api/relay/token", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/relay/token", () => {
  test("keeps legacy token fields and adds policy plus separate preference metadata", async () => {
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps(),
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json() as Record<string, unknown>;
    expect(body.relays).toEqual(["https://relay-one.cmux.dev/"]);
    expect(body.endpointId).toBe(ENDPOINT_ID);
    expect(body.relayCredentials).toEqual([{
      relayUrl: "https://relay-one.cmux.dev/",
      token: body.token,
      expiresAt: 1_700_000_300,
      refreshAfter: 1_700_000_240,
      ttlSeconds: 300,
    }]);
    expect(body.policy).toBe("signed.policy.value");
    expect(body.preference).toEqual({
      mode: "managed",
      selectedManagedRelayIds: ["managed-one"],
      customRelays: [],
    });
    expect(body.preferenceRevision).toBe(3);
    expect(body.ttlSeconds).toBe(300);
    expect(body.expiresAt).toBe(1_700_000_300);

    const [header, payload, signature] = (body.token as string).split(".");
    expect(edVerify(
      null,
      Buffer.from(`${header}.${payload}`),
      publicKey,
      Buffer.from(signature, "base64url"),
    )).toBe(true);
    expect(JSON.parse(Buffer.from(payload, "base64url").toString())).toEqual({
      iss: "cmux",
      aud: "cmux-relay",
      sub: "account-a",
      iat: 1_700_000_000,
      exp: 1_700_000_300,
      endpoint_id: ENDPOINT_ID,
    });
  });

  test("withholds relay credentials until the endpoint has an active broker binding", async () => {
    let mintedCredentials = false;
    const unboundDeps = {
      ...deps({
        issueCredentials: (input) => {
          mintedCredentials = true;
          return mintManagedRelayCredentials({
            sub: input.accountId,
            endpointId: input.endpointId,
            relayUrls: input.relayUrls,
            key: input.key,
            nowSeconds: input.nowSeconds,
          });
        },
      }),
      isEndpointBound: async (input: {
        accountId: string;
        endpointId: string;
        nowSeconds: number;
      }) => {
        expect(input).toEqual({
          accountId: "account-a",
          endpointId: ENDPOINT_ID,
          nowSeconds: 1_700_000_000,
        });
        return false;
      },
    };

    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      unboundDeps,
    );

    expect(response.status).toBe(200);
    expect(mintedCredentials).toBe(false);
    const body = await response.json() as Record<string, unknown>;
    expect(body.endpointId).toBe(ENDPOINT_ID);
    expect(body.policy).toBe("signed.policy.value");
    expect(body.preferenceRevision).toBe(3);
    expect(body.relayCredentials).toBeUndefined();
    expect(body.token).toBeUndefined();
    expect(body.relays).toBeUndefined();
    expect(body.expiresAt).toBeUndefined();
    expect(body.ttlSeconds).toBeUndefined();
  });

  test("preserves distinct URL-token associations without ambiguous legacy fields", async () => {
    const secondRelay = {
      id: "managed-two",
      provider: "other",
      region: "eu-west",
      url: "https://relay-two.example/",
    } as const;
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        signedPolicy: async () => ({
          policy: "signed.policy.value",
          payload: { ...PAYLOAD, relays: [...PAYLOAD.relays, secondRelay] },
          preference: {
            mode: "automatic",
            selectedManagedRelayIds: [],
            customRelays: [],
          },
          preferenceRevision: 4,
        }),
        issueCredentials: ({ relayUrls, nowSeconds }) => relayUrls.map(
          (relayUrl, index) => ({
            relayUrl,
            token: index === 0 ? "abc234" : "def567",
            expiresAt: nowSeconds + 300 + index,
            refreshAfter: nowSeconds + 240 + index,
            ttlSeconds: 300,
          }),
        ),
      }),
    );

    expect(response.status).toBe(200);
    const body = await response.json() as Record<string, unknown>;
    expect(body.relayCredentials).toEqual([
      {
        relayUrl: PAYLOAD.relays[0]?.url,
        token: "abc234",
        expiresAt: 1_700_000_300,
        refreshAfter: 1_700_000_240,
        ttlSeconds: 300,
      },
      {
        relayUrl: secondRelay.url,
        token: "def567",
        expiresAt: 1_700_000_301,
        refreshAfter: 1_700_000_241,
        ttlSeconds: 300,
      },
    ]);
    expect(body.token).toBeUndefined();
    expect(body.relays).toBeUndefined();
  });

  test("omits legacy fields when otherwise shared credentials refresh differently", async () => {
    const secondRelay = {
      id: "managed-two",
      provider: "other",
      region: "eu-west",
      url: "https://relay-two.example/",
    } as const;
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        signedPolicy: async () => ({
          policy: "signed.policy.value",
          payload: { ...PAYLOAD, relays: [...PAYLOAD.relays, secondRelay] },
          preference: {
            mode: "automatic",
            selectedManagedRelayIds: [],
            customRelays: [],
          },
          preferenceRevision: 4,
        }),
        issueCredentials: ({ relayUrls, nowSeconds }) => relayUrls.map(
          (relayUrl, index) => ({
            relayUrl,
            token: "shared-token",
            expiresAt: nowSeconds + 300,
            refreshAfter: nowSeconds + 240 + index,
            ttlSeconds: 300,
          }),
        ),
      }),
    );

    expect(response.status).toBe(200);
    const body = await response.json() as Record<string, unknown>;
    expect(body.relayCredentials).toHaveLength(2);
    expect(body.token).toBeUndefined();
    expect(body.relays).toBeUndefined();
  });

  test("rejects missing, duplicate, and substituted credential URLs", async () => {
    for (const issueCredentials of [
      () => [],
      ({ relayUrls, nowSeconds }: Parameters<RelayTokenDeps["issueCredentials"]>[0]) => [
        {
          relayUrl: relayUrls[0]!,
          token: "abc234",
          expiresAt: nowSeconds + 300,
          refreshAfter: nowSeconds + 240,
          ttlSeconds: 300,
        },
        {
          relayUrl: relayUrls[0]!,
          token: "def567",
          expiresAt: nowSeconds + 300,
          refreshAfter: nowSeconds + 240,
          ttlSeconds: 300,
        },
      ],
      ({ nowSeconds }: Parameters<RelayTokenDeps["issueCredentials"]>[0]) => [{
        relayUrl: "https://attacker.example/",
        token: "abc234",
        expiresAt: nowSeconds + 300,
        refreshAfter: nowSeconds + 240,
        ttlSeconds: 300,
      }],
    ]) {
      const response = await handleRelayTokenRequest(
        request({ endpointId: ENDPOINT_ID }),
        deps({ issueCredentials }),
      );
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "relay_policy_unavailable" });
    }
  });

  test("requires native same-account authentication and a valid endpoint id", async () => {
    const unauthorized = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({ verifyRequest: async () => null }),
    );
    expect(unauthorized.status).toBe(401);

    const invalid = await handleRelayTokenRequest(
      request({ endpointId: "z-base-32-is-not-valid" }),
      deps(),
    );
    expect(invalid.status).toBe(400);
  });

  test("rate limits by authenticated account and fails closed", async () => {
    let key: string | undefined;
    const limited = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        isVercel: () => true,
        rateLimitRuleId: () => "relay-token",
        checkRateLimit: async (_id, options) => {
          key = options.rateLimitKey;
          return { rateLimited: true };
        },
      }),
    );
    expect(limited.status).toBe(429);
    expect(key).toBe("account-a");
    expect(limited.headers.get("retry-after")).toBe("600");

    const unavailable = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({ isVercel: () => true, rateLimitRuleId: () => undefined }),
    );
    expect(unavailable.status).toBe(503);
  });
});
