// Read and update account-scoped Iroh relay selection metadata.
// Custom relay secrets stay in the native client's Keychain and are rejected here.

import { checkRateLimit } from "@vercel/firewall";

import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import { configuredRelayCatalog } from "../../../../services/relay/catalog";
import {
  enforceRelayRateLimit,
  jsonResponse,
  relayErrorResponse,
  runRelayEffect,
  type RelayRateLimitCheck,
} from "../../../../services/relay/http";
import {
  parseRelayPreferenceUpdate,
  type RelayCatalog,
} from "../../../../services/relay/model";
import { runRelayRepositoryEffect } from "../../../../services/relay/repository";
import {
  getRelayPreference,
  putRelayPreference,
  type RelayPreferenceRecord,
} from "../../../../services/relay/workflows";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 32 * 1_024;

export interface RelayPreferenceDeps {
  readonly verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  readonly catalog: () => RelayCatalog;
  readonly getPreference: (accountId: string) => Promise<RelayPreferenceRecord>;
  readonly putPreference: (input: {
    readonly accountId: string;
    readonly expectedRevision?: number;
    readonly preference: ReturnType<typeof parseRelayPreferenceUpdate>["preference"];
    readonly catalog: RelayCatalog;
  }) => Promise<RelayPreferenceRecord>;
  readonly checkRateLimit: RelayRateLimitCheck;
  readonly rateLimitRuleId: () => string | undefined;
  readonly isVercel: () => boolean;
}

const productionDeps: RelayPreferenceDeps = {
  verifyRequest: (request) => verifyRequest(request, { allowCookie: false }),
  catalog: configuredRelayCatalog,
  getPreference: (accountId) =>
    runRelayRepositoryEffect(getRelayPreference(accountId)),
  putPreference: (input) =>
    runRelayRepositoryEffect(putRelayPreference(input)),
  checkRateLimit,
  rateLimitRuleId: () =>
    process.env.CMUX_RELAY_PREFERENCES_RATE_LIMIT_ID ??
    process.env.CMUX_RELAY_TOKEN_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

async function authenticatedAccount(
  request: Request,
  deps: RelayPreferenceDeps,
): Promise<AuthedUser | Response> {
  const user = await deps.verifyRequest(request);
  if (!user) return unauthorized();
  await runRelayEffect(enforceRelayRateLimit({
    request,
    accountId: user.id,
    ruleId: deps.rateLimitRuleId(),
    check: deps.checkRateLimit,
    isVercel: deps.isVercel(),
  }));
  return user;
}

export async function handleGetRelayPreference(
  request: Request,
  deps: RelayPreferenceDeps,
): Promise<Response> {
  try {
    const user = await authenticatedAccount(request, deps);
    if (user instanceof Response) return user;
    const record = await deps.getPreference(user.id);
    return jsonResponse({
      preference: record.preference,
      preferenceRevision: record.revision,
    });
  } catch (error) {
    return relayErrorResponse(error);
  }
}

export async function handlePutRelayPreference(
  request: Request,
  deps: RelayPreferenceDeps,
): Promise<Response> {
  try {
    const user = await authenticatedAccount(request, deps);
    if (user instanceof Response) return user;
    const body = await readBoundedJsonObject(request, MAX_BODY_BYTES);
    if (!body.ok) {
      return jsonResponse(
        { error: body.error },
        body.error === "request_too_large" ? 413 : 400,
      );
    }
    const update = parseRelayPreferenceUpdate(body.value);
    const record = await deps.putPreference({
      accountId: user.id,
      ...(update.expectedRevision === undefined
        ? {}
        : { expectedRevision: update.expectedRevision }),
      preference: update.preference,
      catalog: deps.catalog(),
    });
    return jsonResponse({
      preference: record.preference,
      preferenceRevision: record.revision,
    });
  } catch (error) {
    return relayErrorResponse(error);
  }
}

export function GET(request: Request): Promise<Response> {
  return handleGetRelayPreference(request, productionDeps);
}

export function PUT(request: Request): Promise<Response> {
  return handlePutRelayPreference(request, productionDeps);
}
