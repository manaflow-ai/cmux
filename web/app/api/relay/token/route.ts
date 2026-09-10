// Mint endpoint-bound access credentials and a signed, server-driven Iroh relay policy.
// Auth is native-only because both credentials leave the browser boundary.

import { randomUUID, type KeyObject } from "node:crypto";

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
  relayAuthenticationError,
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
  verifyBindingRequestSignature,
  type IrohBindingRequestProof,
} from "../../../../services/iroh/crypto";
import {
  parseBindingRequestProof,
} from "../../../../services/iroh/routeHandler";
import {
  unauthorized,
  verifyRequestIdentity,
} from "../../../../services/vms/auth";
import { rateLimitDeploymentPartition } from "../../../../services/rateLimitPartition";


const MAX_BODY_BYTES = 4 * 1_024;
// Keep the partition stable for the deployed ten-minute firewall window.
// Including the minute number here would create a fresh bucket every minute.
const RELAY_TOKEN_RATE_LIMIT_BUCKET_SECONDS = 600;

export interface RelayTokenDeps {
  /**
   * Identity only: minting a relay credential needs the account id and nothing
   * else, so this resolves the caller's Stack access token locally instead of
   * spending a `users/me` call on every endpoint refresh.
   */
  readonly verifyRequest: (request: Request) => Promise<{ readonly id: string } | null>;
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
  readonly isEndpointAuthorized: (input: {
    readonly accountId: string;
    readonly endpointId: string;
    readonly clientNamespace: string;
    readonly nowSeconds: number;
    readonly bindingProof: IrohBindingRequestProof | undefined;
  }) => Promise<boolean>;
  readonly checkRateLimit: RelayRateLimitCheck;
  readonly rateLimitRuleId: () => string | undefined;
  readonly isVercel: () => boolean;
  readonly credentialSigningRequired: () => boolean;
}

const productionDeps: RelayTokenDeps = {
  verifyRequest: (request) => verifyRequestIdentity(request, { allowCookie: false, allowStackFallback: false }),
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
  isEndpointAuthorized: async (input) => await runRelayEffect(
    Effect.gen(function* () {
      const repository = yield* IrohRepository;
      const binding = yield* repository.findActiveBindingByEndpoint(
        input.accountId,
        input.endpointId,
      );
      if (!binding || binding.clientNamespace !== input.clientNamespace) {
        return false;
      }
      if (!input.bindingProof) return input.clientNamespace === "legacy";
      if (input.bindingProof.bindingId !== binding.id) return false;
      try {
        verifyBindingRequestSignature({
          ...input.bindingProof,
          endpointId: binding.endpointId,
          nowSeconds: input.nowSeconds,
        });
        return true;
      } catch {
        return false;
      }
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
  credentialSigningRequired: () =>
    process.env.VERCEL === "1" && process.env.VERCEL_ENV !== "preview",
};

export async function handleRelayTokenRequest(
  request: Request,
  deps: RelayTokenDeps,
): Promise<Response> {
  const requestId = randomUUID();
  const errorContext = { requestId };
  let user: { readonly id: string } | null;
  try {
    user = await deps.verifyRequest(request);
  } catch (error) {
    return relayErrorResponse(relayAuthenticationError(error), errorContext);
  }
  if (!user) return unauthorized();

  try {
    const parsed = await parseRelayTokenRequest(request);
    if (parsed instanceof Response) return parsed;
    const { bindingProof, clientNamespace, endpointId } = parsed;
    const key = deps.signingKey();
    const nowSeconds = deps.nowSeconds();
    // Every request consumes quota before database/crypto work, even when
    // the binding lookup fails. Legacy admission cannot depend on the binding
    // result; its bootstrap and credential budgets remain separate below.
    await checkTokenQuota(request, deps, user.id, clientNamespace, endpointId,
      clientNamespace === "legacy" ? "admission" : "credential", requestId);
    const isEndpointAuthorized = await deps.isEndpointAuthorized({
      accountId: user.id,
      endpointId,
      clientNamespace,
      nowSeconds,
      bindingProof,
    });
    if (clientNamespace !== "legacy" && !isEndpointAuthorized) {
      return jsonResponse({ error: "invalid_binding_request_proof" }, 403);
    }

    if (!key && deps.credentialSigningRequired()) {
      return jsonResponse({ error: "relay_token_not_configured" }, 503);
    }
    // A fresh endpoint must fetch policy before registration, then fetch its
    // bound credential immediately after registration. Keep bootstrap and
    // credential issuance in stable, separate partitions.
    if (clientNamespace === "legacy") {
      await checkTokenQuota(request, deps, user.id, clientNamespace, endpointId,
        isEndpointAuthorized ? "credential" : "bootstrap", requestId);
    }
    const policy = await deps.signedPolicy(user.id, nowSeconds);
    const relayUrls = policy.payload.relays.map((relay) => relay.url);

    // Local and preview runtimes intentionally operate without the private
    // relay JWT signer. They still return the signed fleet policy so clients
    // install one coherent account preference and continue with direct/LAN
    // paths. Deployed non-preview runtimes fail closed above.
    const relayCredentials = isEndpointAuthorized && key
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
    return relayErrorResponse(error, errorContext);
  }
}

async function checkTokenQuota(
  request: Request,
  deps: RelayTokenDeps,
  accountId: string,
  namespace: string,
  endpointId: string,
  phase: "credential" | "bootstrap" | "admission",
  requestId: string,
): Promise<void> {
  await runRelayEffect(enforceRelayRateLimit({
    request,
    requestId,
    accountId,
    deploymentPartition: rateLimitDeploymentPartition(),
    devicePartition: `${namespace}:${endpointId}:${phase}`,
    ruleId: deps.rateLimitRuleId(),
    check: deps.checkRateLimit,
    isVercel: deps.isVercel(),
    // The SDK exposes no counter reset timestamp. Its window need not start
    // on a Unix-time boundary, so conservatively wait a full configured window.
    retryAfterSeconds: RELAY_TOKEN_RATE_LIMIT_BUCKET_SECONDS,
  }));
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

type RelayTokenRequest = {
  readonly bindingProof: IrohBindingRequestProof | undefined;
  readonly clientNamespace: string;
  readonly endpointId: string;
};

async function parseRelayTokenRequest(
  request: Request,
): Promise<RelayTokenRequest | Response> {
  const clientNamespace = request.headers.get("x-cmux-app-namespace") ?? "legacy";
  if (!/^[A-Za-z0-9._:-]{1,255}$/.test(clientNamespace)) {
    return jsonResponse({ error: "invalid_client_namespace" }, 400);
  }
  const proofRequest = request.clone();
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
  const bindingProof = parseBindingRequestProof(
    proofRequest,
    new Uint8Array(await proofRequest.arrayBuffer()),
  );
  if (bindingProof instanceof Response) return bindingProof;
  if (clientNamespace !== "legacy" && !bindingProof) {
    return jsonResponse({ error: "binding_request_proof_required" }, 403);
  }
  return {
    bindingProof,
    clientNamespace,
    endpointId: rawEndpointId.toLowerCase(),
  };
}

export function POST(request: Request): Promise<Response> {
  return handleRelayTokenRequest(request, productionDeps);
}
