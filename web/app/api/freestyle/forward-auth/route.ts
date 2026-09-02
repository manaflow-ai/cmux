import { env } from "../../../env";
import {
  authorizePublicationRequest,
  completePublicationAuthorization,
  isRedirectableMethod,
  PUBLICATION_SESSION_TTL_MS,
  PUBLICATION_TRANSACTION_TTL_MS,
  runPublicationAuth,
  type ForwardAuthorizationDecision,
} from "../../../../services/vm-publications/auth";
import {
  PUBLICATION_CALLBACK_PATH,
  PUBLICATION_SESSION_COOKIE,
  PUBLICATION_TRANSACTION_COOKIE,
  clearPublicationCookieHeader,
  normalizePublicationAuthOrigin,
  parsePublicationTransactionCookie,
  publicationCookie,
  publicationCookieHeader,
  publicationHostnameFromHeader,
  publicationSecretMatches,
  safePublicationReturnPath,
} from "../../../../services/vm-publications/security";

const TLS_RULE_ID_PATTERN = /^[A-Za-z0-9._-]{1,256}$/u;
const MAX_FORWARDED_URI_BYTES = 2_048;

export type ForwardAuthHandlerDependencies = {
  readonly serviceSecret: string | undefined;
  readonly authPageOrigin: string | undefined;
  readonly authorize: (input: Parameters<typeof authorizePublicationRequest>[0]) =>
    Promise<ForwardAuthorizationDecision>;
  readonly complete: (input: Parameters<typeof completePublicationAuthorization>[0]) =>
    Promise<
      | { readonly kind: "invalid" }
      | {
        readonly kind: "complete";
        readonly sessionToken: string;
        readonly returnPath: string;
      }
    >;
};

const liveDependencies: ForwardAuthHandlerDependencies = {
  serviceSecret: env.CMUX_VM_PUBLICATION_FORWARD_AUTH_SECRET,
  authPageOrigin: normalizePublicationAuthOrigin(env.CMUX_VM_PUBLICATION_AUTH_ORIGIN) ??
    undefined,
  authorize: (input) => runPublicationAuth(authorizePublicationRequest(input)),
  complete: (input) => runPublicationAuth(completePublicationAuthorization(input)),
};

/**
 * Freestyle's shared forward-auth target. It never authenticates from caller-
 * supplied forwarding headers: the write-only service credential is required
 * before any publication lookup or auth artifact is touched.
 */
export async function GET(request: Request): Promise<Response> {
  return handleForwardAuthRequest(request, liveDependencies);
}

/** Test seam for the trusted-edge HTTP contract; production uses `GET`. */
export async function handleForwardAuthRequest(
  request: Request,
  dependencies: ForwardAuthHandlerDependencies,
): Promise<Response> {
  const serviceToken = bearerToken(request.headers.get("authorization"));
  if (!publicationSecretMatches(
    serviceToken,
    dependencies.serviceSecret,
  )) {
    return response(null, 401);
  }
  if (request.headers.get("x-forwarded-proto")?.toLowerCase() !== "https") {
    return response(null, 400);
  }
  // The sign-in handoff only ever targets the configured CMUX origin. The
  // request's own URL is never consulted: a Host header must not be able to
  // move the browser redirect, so a missing origin fails closed instead.
  const authPageOrigin = normalizePublicationAuthOrigin(dependencies.authPageOrigin);
  if (!authPageOrigin) {
    return response(null, 503);
  }

  const hostname = publicationHostnameFromHeader(
    request.headers.get("x-forwarded-host"),
  );
  const providerTlsRuleId = request.headers
    .get("x-freestyle-tls-rule-id")
    ?.trim() ?? "";
  const method = request.headers.get("x-forwarded-method")?.trim() ?? "";
  const forwardedUri = forwardedRequestUri(
    request.headers.get("x-forwarded-uri"),
  );
  if (
    !hostname ||
    !TLS_RULE_ID_PATTERN.test(providerTlsRuleId) ||
    !method ||
    !forwardedUri
  ) {
    return response(null, 400);
  }

  try {
    if (forwardedUri.pathname === PUBLICATION_CALLBACK_PATH) {
      if (!isRedirectableMethod(method)) return response(null, 400);
      return await callbackResponse(request, {
        hostname,
        code: forwardedUri.searchParams.get("code") ?? "",
        state: forwardedUri.searchParams.get("state") ?? "",
      }, dependencies);
    }

    const decision = await dependencies.authorize({
      hostname,
      providerTlsRuleId,
      method,
      returnPath: safePublicationReturnPath(
        `${forwardedUri.pathname}${forwardedUri.search}`,
      ),
      sessionToken: publicationCookie(
        request.headers.get("cookie"),
        PUBLICATION_SESSION_COOKIE,
      ),
      authPageOrigin,
    });

    if (decision.kind === "allow") return response(null, 204);
    if (decision.kind === "not_found") return response(null, 404);
    if (decision.kind === "unauthorized") return response(null, 401);

    const headers = new Headers({
      "cache-control": "no-store",
      location: decision.location,
    });
    headers.append(
      "set-cookie",
      publicationCookieHeader(
        PUBLICATION_TRANSACTION_COOKIE,
        decision.transactionCookie,
        Math.floor(PUBLICATION_TRANSACTION_TTL_MS / 1_000),
      ),
    );
    return new Response(null, { status: 302, headers });
  } catch (error) {
    console.error("Cloud VM publication forward auth failed", error);
    return response(null, isAuthArtifactError(error) ? 400 : 503);
  }
}

async function callbackResponse(
  request: Request,
  input: { readonly hostname: string; readonly code: string; readonly state: string },
  dependencies: ForwardAuthHandlerDependencies,
): Promise<Response> {
  const transaction = parsePublicationTransactionCookie(publicationCookie(
    request.headers.get("cookie"),
    PUBLICATION_TRANSACTION_COOKIE,
  ));
  if (!transaction) {
    return clearTransactionResponse(400);
  }
  try {
    const completed = await dependencies.complete({
      hostname: input.hostname,
      code: input.code,
      state: input.state,
      transaction: transaction.transaction,
      verifier: transaction.verifier,
    });
    if (completed.kind === "invalid") return clearTransactionResponse(400);

    const headers = new Headers({
      "cache-control": "no-store",
      location: completed.returnPath,
    });
    headers.append(
      "set-cookie",
      publicationCookieHeader(
        PUBLICATION_SESSION_COOKIE,
        completed.sessionToken,
        Math.floor(PUBLICATION_SESSION_TTL_MS / 1_000),
      ),
    );
    headers.append(
      "set-cookie",
      clearPublicationCookieHeader(PUBLICATION_TRANSACTION_COOKIE),
    );
    return new Response(null, { status: 302, headers });
  } catch (error) {
    console.error("Cloud VM publication auth callback failed", error);
    return isAuthArtifactError(error)
      ? clearTransactionResponse(400)
      : response(null, 503);
  }
}

function forwardedRequestUri(value: string | null): URL | null {
  if (
    !value ||
    value.length > MAX_FORWARDED_URI_BYTES ||
    !value.startsWith("/") ||
    value.startsWith("//") ||
    value.startsWith("/\\")
  ) {
    return null;
  }
  try {
    const parsed = new URL(value, "https://publication.invalid");
    return parsed.origin === "https://publication.invalid" ? parsed : null;
  } catch {
    return null;
  }
}

function bearerToken(value: string | null): string | null {
  if (!value?.toLowerCase().startsWith("bearer ")) return null;
  return value.slice("bearer ".length).trim() || null;
}

function clearTransactionResponse(status: number): Response {
  const headers = new Headers({ "cache-control": "no-store" });
  headers.append(
    "set-cookie",
    clearPublicationCookieHeader(PUBLICATION_TRANSACTION_COOKIE),
  );
  return new Response(null, { status, headers });
}

function response(body: BodyInit | null, status: number): Response {
  return new Response(body, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function isAuthArtifactError(error: unknown): boolean {
  return (error as { readonly _tag?: unknown } | null)?._tag ===
    "PublicationAuthArtifactError";
}
