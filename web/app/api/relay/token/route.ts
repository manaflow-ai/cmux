// Mint endpoint-bound access credentials and a signed, server-driven Iroh relay policy.
// Auth is native-only because both credentials leave the browser boundary.

import type { KeyObject } from "node:crypto";

import { checkRateLimit } from "@vercel/firewall";
import * as Effect from "effect/Effect";

import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  enforceRelayRateLimit,
  jsonResponse,
  relayErrorResponse,
  runRelayEffect,
  type RelayRateLimitCheck,
} from "../../../../services/relay/http";
import {
  isValidEndpointId,
  mintManagedRelayCredentials,
  relaySigningKey,
  type ManagedRelayCredentialGrant,
} from "../../../../services/relay/token";
import {
  RelayConfigurationError,
  RelayDatabaseError,
} from "../../../../services/relay/errors";
import {
  productionRelayWorkflowConfig,
  signedRelayPolicy,
  type SignedRelayPolicyResult,
} from "../../../../services/relay/workflows";
import { runRelayRepositoryEffect } from "../../../../services/relay/repository";
import {
  IrohRepository,
  IrohRepositoryLive,
} from "../../../../services/iroh/repository";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 4 * 1_024;
const RELAY_TOKEN_RATE_LIMIT_RETRY_AFTER_SECONDS = 10 * 60;

export interface RelayTokenDeps {
  readonly verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  readonly signingKey: () => KeyObject | null;
  readonly nowSeconds: () => number;
  readonly signedPolicy: (
    accountId: string,
    nowSeconds: number,
  ) => Promise<SignedRelayPolicyResult>;
  readonly issueCredentials: (input: {
    readonly accountId: string;
    readonly endpointId: string;
    readonly relayUrls: readonly string[];
    readonly key: KeyObject;
    readonly nowSeconds: number;
  }) => readonly ManagedRelayCredentialGrant[];
  readonly isEndpointBound: (input: {
    readonly accountId: string;
    readonly endpointId: string;
    readonly nowSeconds: number;
  }) => Promise<boolean>;
  readonly checkRateLimit: RelayRateLimitCheck;
  readonly rateLimitRuleId: () => string | undefined;
  readonly isVercel: () => boolean;
}

const productionDeps: RelayTokenDeps = {
  verifyRequest: (request) => verifyRequest(request, { allowCookie: false }),
  signingKey: relaySigningKey,
  nowSeconds: () => Math.floor(Date.now() / 1_000),
  signedPolicy: async (accountId, nowSeconds) => {
    const config = productionRelayWorkflowConfig();
    return await runRelayRepositoryEffect(signedRelayPolicy(accountId, {
      ...config,
      nowSeconds,
    }));
  },
  issueCredentials: (input) => mintManagedRelayCredentials({
    sub: input.accountId,
    endpointId: input.endpointId,
    relayUrls: input.relayUrls,
    key: input.key,
    nowSeconds: input.nowSeconds,
  }),
  isEndpointBound: async (input) => await runRelayEffect(
    Effect.gen(function* () {
      const repository = yield* IrohRepository;
      const binding = yield* repository.findActiveBindingByEndpoint(
        input.accountId,
        input.endpointId,
      );
      return binding !== null;
    }).pipe(
      Effect.provide(IrohRepositoryLive),
      Effect.mapError((cause) => new RelayDatabaseError({
        operation: "irohBinding.findByEndpoint",
        cause,
      })),
    ),
  ),
  checkRateLimit,
  rateLimitRuleId: () => process.env.CMUX_RELAY_TOKEN_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

export async function handleRelayTokenRequest(
  request: Request,
  deps: RelayTokenDeps,
): Promise<Response> {
  const user = await deps.verifyRequest(request);
  if (!user) return unauthorized();

  try {
    await runRelayEffect(enforceRelayRateLimit({
      request,
      accountId: user.id,
      ruleId: deps.rateLimitRuleId(),
      check: deps.checkRateLimit,
      isVercel: deps.isVercel(),
      retryAfterSeconds: RELAY_TOKEN_RATE_LIMIT_RETRY_AFTER_SECONDS,
    }));

    const key = deps.signingKey();
    if (!key) return jsonResponse({ error: "relay_token_not_configured" }, 503);

    const body = await readBoundedJsonObject(request, MAX_BODY_BYTES);
    if (!body.ok) {
      return jsonResponse(
        { error: body.error },
        body.error === "request_too_large" ? 413 : 400,
      );
    }
    const rawEndpointId = body.value.endpointId;
    if (typeof rawEndpointId !== "string" || !isValidEndpointId(rawEndpointId)) {
      return jsonResponse({ error: "invalid_endpoint_id" }, 400);
    }

    const nowSeconds = deps.nowSeconds();
    const policy = await deps.signedPolicy(user.id, nowSeconds);
    const relayUrls = policy.payload.relays.map((relay) => relay.url);
    const endpointId = rawEndpointId.toLowerCase();
    const isEndpointBound = await deps.isEndpointBound({
      accountId: user.id,
      endpointId,
      nowSeconds,
    });
    const relayCredentials = isEndpointBound
      ? deps.issueCredentials({
        accountId: user.id,
        endpointId,
        relayUrls,
        key,
        nowSeconds,
      })
      : undefined;
    if (
      relayCredentials !== undefined &&
      !hasExactCredentialSet(relayCredentials, relayUrls, nowSeconds)
    ) {
      throw new RelayConfigurationError({ code: "credential_set_invalid" });
    }
    const legacy = relayCredentials
      ? homogeneousLegacyCredential(relayCredentials)
      : null;
    return jsonResponse({
      endpointId,
      ...(relayCredentials ? { relayCredentials } : {}),
      // Homogeneous fleets retain the old fields during client migration.
      ...(legacy
        ? {
            token: legacy.token,
            expiresAt: legacy.expiresAt,
            ttlSeconds: legacy.ttlSeconds,
            relays: relayUrls,
          }
        : {}),
      policy: policy.policy,
      preference: policy.preference,
      preferenceRevision: policy.preferenceRevision,
    });
  } catch (error) {
    return relayErrorResponse(error);
  }
}

function hasExactCredentialSet(
  credentials: readonly ManagedRelayCredentialGrant[],
  relayUrls: readonly string[],
  nowSeconds: number,
): boolean {
  if (credentials.length !== relayUrls.length || credentials.length === 0) {
    return false;
  }
  const expected = new Set(relayUrls);
  const observed = new Set<string>();
  for (const credential of credentials) {
    if (
      !expected.has(credential.relayUrl) ||
      observed.has(credential.relayUrl) ||
      credential.token.length === 0 ||
      credential.token.length > 8 * 1_024 ||
      credential.ttlSeconds < 30 ||
      credential.ttlSeconds > 24 * 60 * 60 ||
      credential.expiresAt <= credential.refreshAfter ||
      credential.refreshAfter <= nowSeconds ||
      credential.refreshAfter < credential.expiresAt - credential.ttlSeconds
    ) {
      return false;
    }
    observed.add(credential.relayUrl);
  }
  return observed.size === expected.size;
}

function homogeneousLegacyCredential(
  credentials: readonly ManagedRelayCredentialGrant[],
): ManagedRelayCredentialGrant | null {
  const first = credentials[0];
  if (!first) return null;
  return credentials.every((credential) =>
    credential.token === first.token &&
    credential.expiresAt === first.expiresAt &&
    credential.refreshAfter === first.refreshAfter &&
    credential.ttlSeconds === first.ttlSeconds
  ) ? first : null;
}

export function POST(request: Request): Promise<Response> {
  return handleRelayTokenRequest(request, productionDeps);
}
