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
    isEndpointAuthorized: async () => true,
    checkRateLimit: async () => ({ rateLimited: false }),
    rateLimitRuleId: () => undefined,
    isVercel: () => false,
    credentialSigningRequired: () => false,
    ...overrides,
  };
}

function request(
  body: unknown,
  clientNamespace?: string,
  includesBindingProof = false,
): Request {
  return new Request("https://cmux.dev/api/relay/token", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(clientNamespace
        ? { "x-cmux-app-namespace": clientNamespace }
        : {}),
      ...(includesBindingProof
        ? {
          "x-cmux-iroh-binding-id": "123e4567-e89b-42d3-a456-426614174090",
          "x-cmux-iroh-request-time": "1700000000",
          "x-cmux-iroh-request-signature": "a".repeat(86),
        }
        : {}),
    },
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
      isEndpointAuthorized: async (input: {
        accountId: string;
        endpointId: string;
        clientNamespace: string;
        nowSeconds: number;
        bindingProof: unknown;
      }) => {
        expect(input).toEqual({
          accountId: "account-a",
          endpointId: ENDPOINT_ID,
          clientNamespace: "legacy",
          nowSeconds: 1_700_000_000,
          bindingProof: undefined,
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

  test("passes the exact app namespace into endpoint ownership checks", async () => {
    let checkedNamespace = "";
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }, "dev.cmux.app.beta", true),
      deps({
        isEndpointAuthorized: async (input) => {
          checkedNamespace = input.clientNamespace;
          return false;
        },
      }),
    );

    expect(response.status).toBe(403);
    expect(checkedNamespace).toBe("dev.cmux.app.beta");
    const body = await response.json() as Record<string, unknown>;
    expect(body.error).toBe("invalid_binding_request_proof");
  });

  test("requires binding proof before accepting a namespaced endpoint claim", async () => {
    let rateLimitChecks = 0;
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }, "dev.cmux.app.beta"),
      deps({
        isVercel: () => true,
        rateLimitRuleId: () => "relay-token",
        checkRateLimit: async () => {
          rateLimitChecks += 1;
          return { rateLimited: false };
        },
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({
      error: "binding_request_proof_required",
    });
    expect(rateLimitChecks).toBe(1);
  });

  test("returns signed policy without private relay credentials in local development", async () => {
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({ signingKey: () => null }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      endpointId: ENDPOINT_ID,
      policy: "signed.policy.value",
      preference: {
        mode: "managed",
        selectedManagedRelayIds: ["managed-one"],
        customRelays: [],
      },
      preferenceRevision: 3,
    });
  });

  test("fails closed without the private relay signer in deployed runtimes", async () => {
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        signingKey: () => null,
        credentialSigningRequired: () => true,
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: "relay_token_not_configured",
    });
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

  test("turns a transient Stack Auth throttle into a retryable response", async () => {
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        verifyRequest: async () => {
          throw new AggregateError(
            [new Error("Rate limited, no retry-after header received")],
            "Stack Auth unavailable",
          );
        },
      }),
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual({ error: "rate_limited" });

    const statusLimited = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        verifyRequest: async () => {
          throw { status: 429, message: "Too many requests" };
        },
      }),
    );
    expect(statusLimited.status).toBe(429);

    const unavailable = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        verifyRequest: async () => {
          throw new Error("Stack Auth connection failed");
        },
      }),
    );
    expect(unavailable.status).toBe(503);
    expect(unavailable.headers.get("retry-after")).toBeNull();
    expect(await unavailable.json()).toEqual({
      error: "authentication_unavailable",
    });
  });

  test("blocks a valid relay request before calling Stack Auth when ingress is limited", async () => {
    let authCalls = 0;
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        isVercel: () => true,
        rateLimitRuleId: () => "relay-token",
        verifyRequest: async () => {
          authCalls += 1;
          return { id: "account-a" } as AuthedUser;
        },
        checkRateLimit: async (_id, options) => {
          expect(options.rateLimitKey).toBeUndefined();
          return { rateLimited: true };
        },
      }),
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(authCalls).toBe(0);
  });

  test("rate limits per account and endpoint and fails closed", async () => {
    let key: string | undefined;
    let checks = 0;
    const limited = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        isVercel: () => true,
        rateLimitRuleId: () => "relay-token",
        checkRateLimit: async (_id, options) => {
          checks += 1;
          key = options.rateLimitKey;
          if (options.rateLimitKey === undefined) return { rateLimited: false };
          return { rateLimited: true };
        },
      }),
    );
    expect(limited.status).toBe(429);
    // Partitioned per device, protocol phase, and minute: a storming endpoint
    // starves only its duplicate work, never bootstrap, renewal, or another
    // phone, simulator, or tagged build.
    expect(key).toBe(
      `account-a:${ENDPOINT_ID.toLowerCase()}:credential:28333333`,
    );
    expect(limited.headers.get("retry-after")).toBe("40");

    // Malformed requests are rejected before the limiter and never consume
    // the per-device budget.
    const invalid = await handleRelayTokenRequest(
      request({ endpointId: "not-an-endpoint" }),
      deps({
        isVercel: () => true,
        rateLimitRuleId: () => "relay-token",
        checkRateLimit: async () => {
          checks += 1;
          return { rateLimited: true };
        },
      }),
    );
    expect(invalid.status).toBe(400);
    expect(checks).toBe(2);

    const blocked = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        isVercel: () => true,
        rateLimitRuleId: () => "relay-token",
        checkRateLimit: async (_id, options) => options.rateLimitKey === undefined
          ? { rateLimited: false }
          : { rateLimited: false, error: "blocked" },
      }),
    );
    expect(blocked.status).toBe(429);

    const unavailable = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        isVercel: () => true,
        rateLimitRuleId: () => "relay-token",
        checkRateLimit: async (_id, options) => {
          if (options.rateLimitKey === undefined) return { rateLimited: false };
          throw new Error("firewall unreachable");
        },
      }),
    );
    expect(unavailable.status).toBe(503);
  });

  test("gives fresh endpoint bootstrap and bound credential renewal separate minute budgets", async () => {
    let nowSeconds = 1_700_000_000;
    let endpointBound = false;
    const consumedPartitions = new Set<string>();
    const observedPartitions: string[] = [];
    const protocolDeps = deps({
      nowSeconds: () => nowSeconds,
      isEndpointAuthorized: async () => endpointBound,
      isVercel: () => true,
      rateLimitRuleId: () => "relay-token",
      checkRateLimit: async (_id, options) => {
        const partition = options.rateLimitKey ?? "";
        if (!partition) return { rateLimited: false };
        observedPartitions.push(partition);
        const rateLimited = consumedPartitions.has(partition);
        consumedPartitions.add(partition);
        return { rateLimited };
      },
    });

    const bootstrap = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      protocolDeps,
    );
    expect(bootstrap.status).toBe(200);
    expect((await bootstrap.json() as Record<string, unknown>).relayCredentials)
      .toBeUndefined();

    endpointBound = true;
    const credential = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      protocolDeps,
    );
    expect(credential.status).toBe(200);
    expect((await credential.json() as Record<string, unknown>).relayCredentials)
      .toHaveLength(1);

    const duplicate = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      protocolDeps,
    );
    expect(duplicate.status).toBe(429);
    expect(duplicate.headers.get("retry-after")).toBe("40");

    nowSeconds += 60;
    const renewal = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      protocolDeps,
    );
    expect(renewal.status).toBe(200);
    expect(new Set(observedPartitions).size).toBe(3);
  });

  test("skips rate limiting when no rule is configured", async () => {
    // An unset rule id env var means the operator wants no rate limiting.
    // This must mint credentials, not 503 every device off the relay network.
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({ isVercel: () => true, rateLimitRuleId: () => undefined }),
    );
    expect(response.status).toBe(200);
  });

  test("fails open when the configured rate-limit rule no longer exists", async () => {
    // Vercel reports a deleted firewall rule as not-found. That is an operator
    // action, not an outage, so the mint must proceed as if unlimited.
    const response = await handleRelayTokenRequest(
      request({ endpointId: ENDPOINT_ID }),
      deps({
        isVercel: () => true,
        rateLimitRuleId: () => "relay-token",
        checkRateLimit: async () => ({ rateLimited: false, error: "not-found" }),
      }),
    );
    expect(response.status).toBe(200);
  });
});
