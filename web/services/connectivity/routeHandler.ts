import * as Effect from "effect/Effect";
import type * as Layer from "effect/Layer";
import { unauthorized, verifyRequest } from "../vms/auth";
import { authProviderErrorResponse } from "../vms/authErrors";
import { jsonResponse } from "../vms/routeHelpers";
import { irohExpectedError } from "../iroh/errors";
import { parseBindingRequestProof } from "../iroh/routeHandler";
import { verifyIrohSessionRequest } from "../iroh/sessionAuth";
import {
  ConnectivityAuthority,
  type ConnectivityAuthorityShape,
} from "./authority";
import { ConnectivityAuthorityRuntime } from "./authorityRuntime";

const MAX_SYNC_BODY_BYTES = 1_024;

type ConnectivityRouteDependencies = {
  readonly verify?: typeof verifyRequest;
  readonly verifySession?: typeof verifyIrohSessionRequest;
  readonly authority?: ConnectivityAuthorityShape;
  readonly runtime?: Layer.Layer<ConnectivityAuthority, never, never>;
};

export async function handleConnectivitySync(
  request: Request,
  dependencies: ConnectivityRouteDependencies = {},
): Promise<Response> {
  return handleConnectivitySyncMethod(request, "sync", dependencies);
}

export async function handleScopedConnectivitySync(
  request: Request,
  dependencies: ConnectivityRouteDependencies = {},
): Promise<Response> {
  return handleConnectivitySyncMethod(request, "syncScoped", dependencies);
}

async function handleConnectivitySyncMethod(
  request: Request,
  method: "sync" | "syncScoped",
  dependencies: ConnectivityRouteDependencies,
): Promise<Response> {
  const verify = dependencies.verify ?? verifyRequest;
  const verifySession = dependencies.verifySession ?? verifyIrohSessionRequest;
  const user = await authenticateConnectivity(request, method, verify, verifySession);
  if (user instanceof Response) return user;
  if (!user) return unauthorized();

  const body = await readSyncBody(request);
  if (!body.ok) return body.response;
  const bindingProof = parseBindingRequestProof(request, body.bytes);
  if (bindingProof instanceof Response) return bindingProof;
  const clientNamespace = request.headers.get("x-cmux-app-namespace")?.trim() ?? "legacy";
  if (!/^[A-Za-z0-9._:-]{1,255}$/.test(clientNamespace)) {
    return jsonResponse({ error: "invalid_client_namespace" }, 400);
  }
  if (user.clientNamespace && user.clientNamespace !== clientNamespace) {
    return jsonResponse({ error: "client_namespace_mismatch" }, 403);
  }

  try {
    const response = dependencies.authority
      ? method === "sync"
        ? await Effect.runPromise(dependencies.authority.sync(
          user.id,
          body.value,
          undefined,
          clientNamespace,
          bindingProof,
        ))
        : await Effect.runPromise(dependencies.authority.syncScoped(
          user.id,
          body.value,
          undefined,
          clientNamespace,
          bindingProof,
        ))
      : method === "sync"
        ? await Effect.runPromise(
          Effect.gen(function* () {
            const authority = yield* ConnectivityAuthority;
            return yield* authority.sync(user.id, body.value, undefined, clientNamespace, bindingProof);
          }).pipe(Effect.provide(dependencies.runtime ?? ConnectivityAuthorityRuntime)),
        )
        : await Effect.runPromise(
          Effect.gen(function* () {
            const authority = yield* ConnectivityAuthority;
            return yield* authority.syncScoped(user.id, body.value, undefined, clientNamespace, bindingProof);
          }).pipe(Effect.provide(dependencies.runtime ?? ConnectivityAuthorityRuntime)),
        );
    return connectivityJsonResponse(response, 200);
  } catch (error) {
    const expected = irohExpectedError(error);
    if (expected) return connectivityExpectedErrorResponse(expected);
    console.error("connectivity sync failed", { failure: "unexpected" });
    return jsonResponse({ error: "connectivity_internal_error" }, 500);
  }
}

async function authenticateConnectivity(
  request: Request,
  method: "sync" | "syncScoped",
  verify: typeof verifyRequest,
  verifySession: typeof verifyIrohSessionRequest,
): Promise<{ readonly id: string; readonly clientNamespace?: string } | null | Response> {
  const session = verifySession(request);
  if (session.ok) {
    return {
      id: session.identity.accountId,
      ...(session.identity.clientNamespace
        ? { clientNamespace: session.identity.clientNamespace }
        : {}),
    };
  }
  if (session.error !== "missing") {
    return jsonResponse(
      { error: session.error === "not_configured" ? "iroh_session_not_configured" : "iroh_session_invalid" },
      session.error === "not_configured" ? 503 : 401,
    );
  }
  try {
    return await verify(request, { allowCookie: false });
  } catch (error) {
    return authProviderErrorResponse(error, `connectivity.${method}.auth`);
  }
}

async function readSyncBody(request: Request): Promise<
  | { readonly ok: true; readonly value: unknown; readonly bytes: Uint8Array }
  | { readonly ok: false; readonly response: Response }
> {
  if (
    request.method !== "POST"
    || request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase()
      !== "application/json"
  ) {
    return {
      ok: false,
      response: jsonResponse({ error: "unsupported_media_type" }, 415),
    };
  }
  const contentLength = request.headers.get("content-length");
  if (contentLength) {
    const parsed = Number(contentLength);
    if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > MAX_SYNC_BODY_BYTES) {
      return {
        ok: false,
        response: jsonResponse({ error: "request_too_large" }, 413),
      };
    }
  }
  const reader = request.body?.getReader();
  if (!reader) {
    return { ok: false, response: jsonResponse({ error: "missing_body" }, 400) };
  }
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > MAX_SYNC_BODY_BYTES) {
        await reader.cancel();
        return {
          ok: false,
          response: jsonResponse({ error: "request_too_large" }, 413),
        };
      }
      chunks.push(next.value);
    }
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_body" }, 400) };
  }
  if (total === 0) {
    return { ok: false, response: jsonResponse({ error: "missing_body" }, 400) };
  }
  const bytes = Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), total);
  try {
    return {
      ok: true,
      value: JSON.parse(bytes.toString("utf8")),
      bytes: new Uint8Array(bytes),
    };
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_json" }, 400) };
  }
}

function connectivityExpectedErrorResponse(
  error: NonNullable<ReturnType<typeof irohExpectedError>>,
): Response {
  switch (error._tag) {
    case "IrohInvalidInputError":
      return connectivityJsonResponse({ error: error.code }, 400);
    case "IrohForbiddenError":
      return connectivityJsonResponse({ error: error.code }, 403);
    case "IrohNotFoundError":
      return connectivityJsonResponse({ error: `${error.resource}_not_found` }, 404);
    case "IrohConflictError":
      return connectivityJsonResponse({ error: error.code }, 409);
    case "IrohQuotaExceededError":
      return new Response(JSON.stringify({
        error: error.code,
        retry_after_seconds: error.retryAfterSeconds,
      }), {
        status: 429,
        headers: {
          "content-type": "application/json",
          "cache-control": "no-store",
          "retry-after": String(error.retryAfterSeconds),
        },
      });
    case "IrohConfigurationError":
    case "IrohDatabaseError":
    case "IrohRelayMintError":
      return connectivityJsonResponse({ error: "connectivity_service_unavailable" }, 503);
  }
}

function connectivityJsonResponse(value: unknown, status: number): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
    },
  });
}
