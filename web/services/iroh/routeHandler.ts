import { checkRateLimit } from "@vercel/firewall";
import { createHash } from "node:crypto";
import * as Effect from "effect/Effect";
import type * as Layer from "effect/Layer";
import { env } from "../../app/env";
import { unauthorized, verifyRequest, type AuthedUser } from "../vms/auth";
import { enforceBrowserMutationProtection, jsonResponse } from "../vms/routeHelpers";
import { irohExpectedError } from "./errors";
import {
  IrohTrustBroker,
  IrohTrustBrokerRuntime,
  type IrohTrustBrokerShape,
} from "./trustBroker";

const MAX_BODY_BYTES = 64 * 1_024;

export type IrohRouteOperation =
  | "challenge"
  | "register"
  | "discover"
  | "revoke"
  | "pair_grant"
  | "relay_token";

type RouteDependencies = {
  readonly verify?: typeof verifyRequest;
  readonly broker?: IrohTrustBrokerShape;
  readonly runtime?: Layer.Layer<IrohTrustBroker, never, never>;
};

export async function handleIrohRoute(
  request: Request,
  operation: IrohRouteOperation,
  dependencies: RouteDependencies = {},
): Promise<Response> {
  const verify = dependencies.verify ?? verifyRequest;
  let user: AuthedUser | null;
  try {
    user = await verify(request, { allowCookie: false });
  } catch {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  if (!user) return unauthorized();

  if (process.env.VERCEL === "1" && env.CMUX_IROH_RATE_LIMIT_ID) {
    const { error, rateLimited } = await checkRateLimit(env.CMUX_IROH_RATE_LIMIT_ID, {
      request,
      rateLimitKey: createHash("sha256").update(`iroh-rate:${user.id}:${operation}`).digest("hex"),
    });
    if (rateLimited || error === "blocked") {
      return irohJsonResponse({ error: "rate_limited" }, 429, { "retry-after": "60" });
    }
    if (error) {
      console.error("iroh trust broker firewall unavailable", { operation, failure: error });
      return jsonResponse({ error: "iroh_service_unavailable" }, 503);
    }
  }

  if (operation !== "discover") {
    const mutationForbidden = enforceBrowserMutationProtection(request);
    if (mutationForbidden) return mutationForbidden;
  }

  const bodyResult = operation === "discover"
    ? { ok: true as const, value: undefined }
    : await readBoundedJson(request);
  if (!bodyResult.ok) return bodyResult.response;

  try {
    const value = dependencies.broker
      ? await Effect.runPromise(invoke(dependencies.broker, operation, user.id, bodyResult.value))
      : await Effect.runPromise(
        Effect.gen(function* () {
          const broker = yield* IrohTrustBroker;
          return yield* invoke(broker, operation, user.id, bodyResult.value);
        }).pipe(Effect.provide(dependencies.runtime ?? IrohTrustBrokerRuntime)),
      );
    return irohJsonResponse(value, successStatus(operation), {
      "cache-control": "no-store",
    });
  } catch (error) {
    const expected = irohExpectedError(error);
    if (expected) return expectedErrorResponse(expected);
    // Do not include EndpointIDs, hints, grants, or tokens in logs. The route
    // and coarse failure class are enough for operational correlation.
    console.error("iroh trust broker request failed", { operation, failure: "unexpected" });
    return jsonResponse({ error: "iroh_internal_error" }, 500);
  }
}

function invoke(
  broker: IrohTrustBrokerShape,
  operation: IrohRouteOperation,
  userId: string,
  body: unknown,
) {
  switch (operation) {
    case "challenge": return broker.issueChallenge(userId, body);
    case "register": return broker.register(userId, body);
    case "discover": return broker.discover(userId);
    case "revoke": return broker.revoke(userId, body);
    case "pair_grant": return broker.issuePairGrant(userId, body);
    case "relay_token": return broker.issueRelayToken(userId, body);
  }
}

async function readBoundedJson(request: Request): Promise<
  | { readonly ok: true; readonly value: unknown }
  | { readonly ok: false; readonly response: Response }
> {
  if (request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
    return { ok: false, response: jsonResponse({ error: "unsupported_media_type" }, 415) };
  }
  const contentLength = request.headers.get("content-length");
  if (contentLength) {
    const parsed = Number(contentLength);
    if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > MAX_BODY_BYTES) {
      return { ok: false, response: jsonResponse({ error: "request_too_large" }, 413) };
    }
  }
  const reader = request.body?.getReader();
  if (!reader) return { ok: false, response: jsonResponse({ error: "missing_body" }, 400) };
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > MAX_BODY_BYTES) {
        await reader.cancel();
        return { ok: false, response: jsonResponse({ error: "request_too_large" }, 413) };
      }
      chunks.push(next.value);
    }
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_body" }, 400) };
  }
  if (total === 0) return { ok: false, response: jsonResponse({ error: "missing_body" }, 400) };
  const bytes = Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), total);
  try {
    return { ok: true, value: JSON.parse(bytes.toString("utf8")) };
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_json" }, 400) };
  }
}

function successStatus(operation: IrohRouteOperation): number {
  return operation === "discover" || operation === "revoke" ? 200 : 201;
}

function expectedErrorResponse(error: ReturnType<typeof irohExpectedError> & object): Response {
  const tag = (error as { _tag?: string })._tag;
  if (tag === "IrohInvalidInputError") {
    return jsonResponse({ error: (error as { code: string }).code }, 400);
  }
  if (tag === "IrohForbiddenError") {
    return jsonResponse({ error: (error as { code: string }).code }, 403);
  }
  if (tag === "IrohNotFoundError") {
    return jsonResponse({ error: `${(error as { resource: string }).resource}_not_found` }, 404);
  }
  if (tag === "IrohConflictError") {
    return jsonResponse({ error: (error as { code: string }).code }, 409);
  }
  if (tag === "IrohQuotaExceededError") {
    const quota = error as { code: string; retryAfterSeconds: number };
    return irohJsonResponse(
      { error: quota.code, retry_after_seconds: quota.retryAfterSeconds },
      429,
      { "retry-after": String(quota.retryAfterSeconds) },
    );
  }
  if (tag === "IrohConfigurationError" || tag === "IrohRelayMintError") {
    return jsonResponse({ error: "iroh_service_unavailable" }, 503);
  }
  return jsonResponse({ error: "iroh_database_unavailable" }, 503);
}

function irohJsonResponse(
  value: unknown,
  status: number,
  headers: Record<string, string>,
): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}
