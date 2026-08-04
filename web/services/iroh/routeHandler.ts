import * as Effect from "effect/Effect";
import type * as Layer from "effect/Layer";
import { after } from "next/server";
import { env } from "../../app/env";
import { unauthorized, verifyRequest, type AuthedUser } from "../vms/auth";
import { enforceBrowserMutationProtection, jsonResponse } from "../vms/routeHelpers";
import { irohExpectedError } from "./errors";
import {
  IrohTrustBroker,
  IrohTrustBrokerRuntime,
  type IrohTrustBrokerShape,
} from "./trustBroker";
import { parseIrohDiscoveryRequest } from "./discoveryPagination";

const MAX_BODY_BYTES = 64 * 1_024;
const INVALIDATION_TIMEOUT_MS = 750;

export type IrohRouteOperation =
  | "challenge"
  | "register"
  | "discover"
  | "endpoint_attestation"
  | "revoke"
  | "pair_grant"
  | "relay_token";

type RouteDependencies = {
  readonly verify?: typeof verifyRequest;
  readonly broker?: IrohTrustBrokerShape;
  readonly runtime?: Layer.Layer<IrohTrustBroker, never, never>;
  readonly publishConnectivityInvalidation?: (
    request: Request,
    revision: number,
  ) => Promise<void>;
  readonly scheduleAfterResponse?: (
    operation: () => Promise<void>,
  ) => void;
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

  if (operation !== "discover") {
    const mutationForbidden = enforceBrowserMutationProtection(request);
    if (mutationForbidden) return mutationForbidden;
  }

  let bodyResult: Awaited<ReturnType<typeof readBoundedJson>> | undefined;
  if (operation === "discover") {
    const discovery = discoveryRequest(request);
    if (!discovery.ok) return discovery.response;
    bodyResult = { ok: true, value: discovery.value };
  }

  bodyResult ??= await readBoundedJson(request);
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
    const revision = mutationRevision(operation, value);
    if (revision !== null) {
      const publication = async () => {
        try {
          await (dependencies.publishConnectivityInvalidation
            ?? publishConnectivityInvalidation)(request, revision);
        } catch {
          // The mutation is already committed. Push only accelerates the next
          // v2 reconciliation, so a worker outage must not turn success into an
          // ambiguous client retry of a committed mutation.
          console.warn("connectivity invalidation publish failed", { operation });
        }
      };
      if (dependencies.scheduleAfterResponse) {
        dependencies.scheduleAfterResponse(publication);
      } else if (dependencies.publishConnectivityInvalidation) {
        await publication();
      } else {
        after(publication);
      }
    }
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

function mutationRevision(
  operation: IrohRouteOperation,
  value: unknown,
): number | null {
  if (operation !== "register" && operation !== "revoke") return null;
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const revision = (value as Record<string, unknown>).revision;
  return Number.isSafeInteger(revision) && (revision as number) > 0
    ? revision as number
    : null;
}

async function publishConnectivityInvalidation(
  request: Request,
  revision: number,
): Promise<void> {
  const publication = buildConnectivityInvalidationRequest(request, revision);
  if (!publication) return;
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(new Error("connectivity_invalidation_timeout")),
    INVALIDATION_TIMEOUT_MS,
  );
  try {
    const response = await fetch(publication, { signal: controller.signal });
    if (!response.ok) throw new Error("connectivity_invalidation_rejected");
  } finally {
    clearTimeout(timeout);
  }
}

/** Builds the exact backend-only worker publication without performing I/O. */
export function buildConnectivityInvalidationRequest(
  request: Request,
  revision: number,
  configuration: {
    readonly baseURL?: string;
    readonly publisherSecret?: string;
  } = {
    baseURL: env.CMUX_PRESENCE_BASE_URL,
    publisherSecret: env.CMUX_CONNECTIVITY_INVALIDATION_SECRET,
  },
): Request | null {
  const { baseURL, publisherSecret } = configuration;
  if (!baseURL || !publisherSecret) return null;
  const authorization = request.headers.get("authorization")?.trim();
  if (!authorization?.toLowerCase().startsWith("bearer ")) return null;
  return new Request(new URL("/v1/connectivity/invalidate", baseURL), {
    method: "POST",
    headers: {
      authorization,
      "content-type": "application/json",
      "x-cmux-connectivity-publisher-secret": publisherSecret,
    },
    body: JSON.stringify({ revision }),
  });
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
    case "discover": return broker.discover(userId, undefined, body);
    case "endpoint_attestation": return broker.issueEndpointAttestation(userId, body);
    case "revoke": return broker.revoke(userId, body);
    case "pair_grant": return broker.issuePairGrant(userId, body);
    case "relay_token": return broker.issueRelayToken(userId, body);
  }
}

function discoveryRequest(request: Request):
  | { readonly ok: true; readonly value: unknown }
  | { readonly ok: false; readonly response: Response } {
  const url = new URL(request.url);
  const allowed = new Set(["page_size", "cursor"]);
  if (
    [...url.searchParams.keys()].some((key) => !allowed.has(key)) ||
    url.searchParams.getAll("page_size").length > 1 ||
    url.searchParams.getAll("cursor").length > 1
  ) {
    return {
      ok: false,
      response: jsonResponse({ error: "invalid_discovery_page_size" }, 400),
    };
  }
  const pageSize = url.searchParams.get("page_size");
  const cursor = url.searchParams.get("cursor");
  if (pageSize === null && cursor === null) {
    return { ok: true, value: undefined };
  }
  const value = {
    ...(pageSize === null ? {} : { pageSize }),
    ...(cursor === null ? {} : { cursor }),
  };
  try {
    parseIrohDiscoveryRequest(value);
    return { ok: true, value };
  } catch (error) {
    const code = error && typeof error === "object" &&
        (error as { _tag?: unknown })._tag === "IrohInvalidInputError"
      ? (error as { code: string }).code
      : "invalid_discovery_page_size";
    return { ok: false, response: jsonResponse({ error: code }, 400) };
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
  return jsonResponse({ error: "iroh_service_unavailable" }, 503);
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
