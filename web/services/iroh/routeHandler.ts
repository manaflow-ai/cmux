import { createHash } from "node:crypto";
import * as Effect from "effect/Effect";
import type * as Layer from "effect/Layer";
import { env } from "../../app/env";
import { unauthorized, verifyRequest, type AuthedUser } from "../vms/auth";
import { enforceBrowserMutationProtection, jsonResponse } from "../vms/routeHelpers";
import { irohExpectedError } from "./errors";
import {
  checkIrohVercelFirewall,
  type IrohFirewallCheck,
  type IrohFirewallCheckResult,
} from "./firewall";
import {
  IrohTrustBroker,
  IrohTrustBrokerRuntime,
  type IrohTrustBrokerShape,
} from "./trustBroker";

const MAX_BODY_BYTES = 64 * 1_024;
const FIREWALL_TIMEOUT_MS = 2_500;
const FIREWALL_MAX_IN_FLIGHT = 64;

export class IrohFirewallAdmission {
  private readonly active = new Map<string, Promise<IrohFirewallCheckResult>>();

  constructor(private readonly maxInFlight: number) {
    if (!Number.isSafeInteger(maxInFlight) || maxInFlight <= 0) {
      throw new RangeError("maxInFlight must be a positive integer");
    }
  }

  get activeCount(): number {
    return this.active.size;
  }

  run(key: string, start: () => Promise<IrohFirewallCheckResult>): Promise<IrohFirewallCheckResult> {
    if (this.active.has(key) || this.active.size >= this.maxInFlight) {
      throw new Error("firewall_admission_unavailable");
    }

    const work = Promise.resolve().then(start);
    const tracked = work.finally(() => {
      if (this.active.get(key) === tracked) this.active.delete(key);
    });
    this.active.set(key, tracked);
    return tracked;
  }
}

const firewallAdmission = new IrohFirewallAdmission(FIREWALL_MAX_IN_FLIGHT);

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
  readonly firewall?: {
    readonly id: string;
    readonly check: IrohFirewallCheck;
    readonly timeoutMs?: number;
    readonly admission?: IrohFirewallAdmission;
  };
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

  // Challenge and registration bodies carry the authenticated app identity.
  // Read their already-bounded JSON before the platform firewall so concurrent
  // app instances do not consume one account-wide bucket. The broker's database
  // quotas remain account- and physical-device-wide, so varying this partition
  // cannot bypass the global safety bounds.
  let bodyResult: Awaited<ReturnType<typeof readBoundedJson>> | undefined;
  if (operation === "challenge" || operation === "register") {
    bodyResult = await readBoundedJson(request);
    if (!bodyResult.ok) return bodyResult.response;
  }

  const firewall = dependencies.firewall ?? (
    process.env.VERCEL === "1" && env.CMUX_IROH_RATE_LIMIT_ID
      ? { id: env.CMUX_IROH_RATE_LIMIT_ID, check: checkIrohVercelFirewall }
      : undefined
  );
  if (firewall) {
    const identityPartition = bodyResult?.ok
      ? registrationFirewallPartition(operation, bodyResult.value)
      : undefined;
    const rateLimitKey = createHash("sha256")
      .update(`iroh-rate:${user.id}:${operation}:${identityPartition ?? "account"}`)
      .digest("hex");
    const abortController = new AbortController();
    const timeout = setTimeout(
      () => abortController.abort(new Error("firewall_timeout")),
      firewall.timeoutMs ?? FIREWALL_TIMEOUT_MS,
    );
    let result: IrohFirewallCheckResult;
    try {
      result = await (firewall.admission ?? firewallAdmission).run(
        `${firewall.id}:${rateLimitKey}`,
        () => firewall.check(firewall.id, {
          request,
          rateLimitKey,
          signal: abortController.signal,
        }),
      );
    } catch {
      console.error("iroh trust broker firewall unavailable", {
        operation,
        failure: "request_failed_or_timed_out",
      });
      return jsonResponse({ error: "iroh_service_unavailable" }, 503);
    } finally {
      clearTimeout(timeout);
    }
    const { error, rateLimited } = result;
    if (rateLimited || error === "blocked") {
      return irohJsonResponse({ error: "rate_limited" }, 429, { "retry-after": "60" });
    }
    if (error) {
      console.error("iroh trust broker firewall unavailable", { operation, failure: error });
      return jsonResponse({ error: "iroh_service_unavailable" }, 503);
    }
  }

  bodyResult ??= operation === "discover"
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

function registrationFirewallPartition(
  operation: IrohRouteOperation,
  body: unknown,
): string | undefined {
  let identity: unknown = body;
  if (operation === "register") {
    const payload = recordString(body, "payload");
    if (!payload || payload.length > 48_000) return undefined;
    try {
      const decoded = Buffer.from(payload, "base64url");
      if (decoded.byteLength === 0 || decoded.byteLength > 32_768) return undefined;
      identity = JSON.parse(decoded.toString("utf8"));
    } catch {
      return undefined;
    }
  } else if (operation !== "challenge") {
    return undefined;
  }

  const deviceId = registrationUUID(identity, "deviceId");
  const appInstanceId = registrationUUID(identity, "appInstanceId");
  if (!deviceId || !appInstanceId) return undefined;
  return `device:${deviceId}:instance:${appInstanceId}`;
}

function recordString(value: unknown, key: string): string | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
  const field = (value as Record<string, unknown>)[key];
  return typeof field === "string" ? field : undefined;
}

function registrationUUID(value: unknown, key: string): string | undefined {
  const candidate = recordString(value, key);
  if (!candidate || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(candidate)) {
    return undefined;
  }
  return candidate.toLowerCase();
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
    case "endpoint_attestation": return broker.issueEndpointAttestation(userId, body);
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
