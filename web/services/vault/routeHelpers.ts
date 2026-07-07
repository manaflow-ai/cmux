import type { Span } from "@opentelemetry/api";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
  type MaybeAttributes,
} from "@/services/telemetry";
import { isVaultConfigured } from "@/services/vault/config";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "@/services/vms/auth";
import {
  browserMutationContentTypeAllowed,
  browserMutationOriginAllowed,
  jsonResponse,
  parseBearer,
  requiresBrowserMutationProtection,
} from "@/services/vms/routeHelpers";

type VerifyRequestOptions = NonNullable<Parameters<typeof verifyRequest>[1]>;

export type VaultRouteContext = {
  readonly span: Span;
  readonly setResponseFinalizer: (
    finalizer: ((response: Response) => void) | null,
  ) => void;
};

export type AuthedVaultRouteContext = VaultRouteContext & {
  readonly user: AuthedUser;
};

export async function withVaultApiRoute(
  request: Request,
  route: string,
  attributes: MaybeAttributes,
  failureLog: string,
  handler: (context: VaultRouteContext) => Promise<Response>,
): Promise<Response> {
  return withApiRouteSpan(
    request,
    route,
    { "cmux.subsystem": "vault", ...attributes },
    async (span) => {
      return runVaultRoute(span, failureLog, async (context) => {
        if (!isVaultConfigured()) {
          return jsonResponse({ error: "vault_not_configured" }, 503);
        }
        return handler(context);
      });
    },
  );
}

export async function withAuthedVaultApiRoute(
  request: Request,
  route: string,
  attributes: MaybeAttributes,
  failureLog: string,
  verifyOptions: VerifyRequestOptions,
  handler: (context: AuthedVaultRouteContext) => Promise<Response>,
  // Injectable so tests can pin the auth outcome regardless of module mocks
  // other suites install for app/lib/stack in the shared bun test process.
  verify: typeof verifyRequest = verifyRequest,
): Promise<Response> {
  return withVaultApiRoute(request, route, attributes, failureLog, async (context) => {
    const user = await verify(request, verifyOptions);
    if (!user) return unauthorized();
    const bearer = parseBearer(request);
    if (requiresBrowserMutationProtection(request.method, bearer)) {
      if (!browserMutationOriginAllowed(request) || !browserMutationContentTypeAllowed(request)) {
        return jsonResponse({ error: "forbidden" }, 403);
      }
    }
    setSpanAttributes(context.span, { "cmux.vault.user_id": user.id });
    return handler({ ...context, user });
  });
}

async function runVaultRoute(
  span: Span,
  failureLog: string,
  handler: (context: VaultRouteContext) => Promise<Response>,
): Promise<Response> {
  let responseFinalizer: ((response: Response) => void) | null = null;
  const setResponseFinalizer = (
    finalizer: ((response: Response) => void) | null,
  ) => {
    responseFinalizer = finalizer;
  };

  const finalize = (response: Response): Response => {
    setSpanAttributes(span, {
      "cmux.vault.outcome": outcomeFromStatus(response.status),
    });
    if (!responseFinalizer) return response;
    try {
      responseFinalizer(response);
    } catch (error) {
      recordSpanError(span, error);
      console.error(`${failureLog}: response finalizer failed`, error);
    }
    return response;
  };

  try {
    return finalize(await handler({ span, setResponseFinalizer }));
  } catch (error) {
    recordSpanError(span, error);
    console.error(failureLog, error);
    return finalize(jsonResponse({ error: "internal_error" }, 500));
  }
}

function outcomeFromStatus(status: number): string {
  if (status === 401) return "unauthorized";
  if (status === 403) return "forbidden";
  if (status === 404) return "not_found";
  if (status === 409) return "conflict";
  if (status === 429) return "throttled";
  if (status === 503) return "unavailable";
  if (status >= 500) return "internal_error";
  if (status >= 400) return "client_error";
  return "ok";
}
