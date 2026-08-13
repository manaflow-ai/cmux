import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import * as Context from "effect/Context";
import * as Layer from "effect/Layer";

import {
  AccountDeletionMutationBlockedError,
} from "../account/deletionLock";
import type { hasActiveCoderouterSubscription } from "../billing/pro";
import { captureCoderouterEvent } from "./analytics";
import { CodeRouterHandoffEntitlementDenied } from "./repository";
import type {
  exchangeCoderouterHandoffLease,
  issueCoderouterHandoffLease,
  CodeRouterHandoffAuthorizer,
  CodeRouterHandoffEntitlementDb,
  CodeRouterHandoffIdentity,
} from "./repository";
import type { resolveCodeRouterRequestContext } from "./requestContext";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";

export type HandoffRateLimitOutcome =
  | "allowed"
  | "limited"
  | "unavailable";

export type HandoffProtocol = {
  readonly rateLimit: (
    request: Request,
  ) => Promise<HandoffRateLimitOutcome>;
  readonly hasNativeStackAuthHeaders: (request: Request) => boolean;
  readonly isBoundedNativeStackRequest: (request: Request) => boolean;
  readonly validTeamSelectorHeaders: (request: Request) => boolean;
  readonly hasTeamSelector: (request: Request) => boolean;
  readonly coderouterOpenaiBaseUrl: (
    request: Request,
    configuredOrigin?: string,
  ) => string | null;
  readonly readBoundedBody: (
    request: Request,
  ) => Promise<HandoffBodyResult>;
  readonly isJsonContentType: (request: Request) => boolean;
  readonly parseEmptyHandoffBody: (body: string) => boolean;
  readonly parseHandoffLeaseBody: (body: string) => string | null;
};

export type HandoffBodyResult =
  | { readonly ok: true; readonly body: string }
  | { readonly ok: false; readonly status: 400 | 413 };

export class HandoffResponseError extends Data.TaggedError(
  "HandoffResponseError",
)<{
  readonly response: Response;
}> {}

export class HandoffRateLimitError extends Data.TaggedError(
  "HandoffRateLimitError",
)<{
  readonly outcome: Exclude<HandoffRateLimitOutcome, "allowed">;
}> {}

export class HandoffUnauthorizedError extends Data.TaggedError(
  "HandoffUnauthorizedError",
)<Record<string, never>> {}

export class HandoffInvalidRequestError extends Data.TaggedError(
  "HandoffInvalidRequestError",
)<Record<string, never>> {}

export class HandoffPayloadTooLargeError extends Data.TaggedError(
  "HandoffPayloadTooLargeError",
)<Record<string, never>> {}

export class HandoffForbiddenError extends Data.TaggedError(
  "HandoffForbiddenError",
)<Record<string, never>> {}

export class HandoffAuthorizationUnavailableError extends Data.TaggedError(
  "HandoffAuthorizationUnavailableError",
)<Record<string, never>> {}

export class HandoffEntitlementRequiredError extends Data.TaggedError(
  "HandoffEntitlementRequiredError",
)<Record<string, never>> {}

export class HandoffEntitlementUnavailableError extends Data.TaggedError(
  "HandoffEntitlementUnavailableError",
)<Record<string, never>> {}

export class HandoffAccountDeletionBlockedError extends Data.TaggedError(
  "HandoffAccountDeletionBlockedError",
)<Record<string, never>> {}

export class HandoffConfigurationError extends Data.TaggedError(
  "HandoffConfigurationError",
)<Record<string, never>> {}

export class HandoffPersistenceError extends Data.TaggedError(
  "HandoffPersistenceError",
)<{
  readonly operation: "mint" | "exchange";
}> {}

export class HandoffInvalidLeaseError extends Data.TaggedError(
  "HandoffInvalidLeaseError",
)<Record<string, never>> {}

class HandoffAuthorizerUnavailableError extends Error {}

export type HandoffWorkflowError =
  | HandoffResponseError
  | HandoffRateLimitError
  | HandoffUnauthorizedError
  | HandoffInvalidRequestError
  | HandoffPayloadTooLargeError
  | HandoffForbiddenError
  | HandoffAuthorizationUnavailableError
  | HandoffEntitlementRequiredError
  | HandoffEntitlementUnavailableError
  | HandoffAccountDeletionBlockedError
  | HandoffConfigurationError
  | HandoffPersistenceError
  | HandoffInvalidLeaseError;

export type HandoffMintDependencies = {
  readonly protocol: HandoffProtocol;
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly hasActiveEntitlement: typeof hasActiveCoderouterSubscription;
  readonly issueLease: typeof issueCoderouterHandoffLease;
  readonly hostedProRequired: () => boolean;
  readonly now?: () => Date;
};

export type HandoffExchangeDependencies = {
  readonly protocol: HandoffProtocol;
  readonly exchangeLease: typeof exchangeCoderouterHandoffLease;
  readonly resolveContext: typeof resolveCodeRouterRequestContext;
  readonly hasActiveEntitlement: typeof hasActiveCoderouterSubscription;
  readonly hostedProRequired: () => boolean;
  readonly publicOrigin?: () => string | undefined;
  readonly now?: () => Date;
};

export type HandoffWorkflowShape = {
  readonly mint: (
    request: Request,
  ) => Effect.Effect<HandoffMintResult, HandoffWorkflowError>;
  readonly exchange: (
    request: Request,
    lease?: string,
  ) => Effect.Effect<HandoffExchangeResult, HandoffWorkflowError>;
};

export class HandoffWorkflow extends Context.Tag(
  "cmux/CodeRouterHandoffWorkflow",
)<HandoffWorkflow, HandoffWorkflowShape>() {}

export type HandoffMintResult = Awaited<
  ReturnType<typeof issueCoderouterHandoffLease>
> & {
  readonly teamId: string;
  readonly stackUserId: string;
};

export type HandoffExchangeResult = NonNullable<
  Awaited<ReturnType<typeof exchangeCoderouterHandoffLease>>
> & {
  readonly openaiBaseUrl: string;
};

function tryPromise<A, E>(
  run: () => Promise<A>,
  onFailure: (cause: unknown) => E,
): Effect.Effect<A, E> {
  return Effect.tryPromise({
    try: run,
    catch: onFailure,
  });
}

function rateLimit(
  request: Request,
  protocol: HandoffProtocol,
): Effect.Effect<void, HandoffRateLimitError> {
  return tryPromise(
    () => protocol.rateLimit(request),
    () => new HandoffRateLimitError({ outcome: "unavailable" }),
  ).pipe(
    Effect.flatMap((outcome) =>
      outcome === "allowed"
        ? Effect.succeed(undefined)
        : Effect.fail(new HandoffRateLimitError({ outcome })),
    ),
  );
}

function readHandoffBody(
  request: Request,
  protocol: HandoffProtocol,
): Effect.Effect<
  string,
  HandoffInvalidRequestError | HandoffPayloadTooLargeError
> {
  return Effect.gen(function* () {
    const body = yield* Effect.tryPromise({
      try: () => protocol.readBoundedBody(request),
      catch: () => new HandoffInvalidRequestError({}),
    });
    if (body.ok) return body.body;
    if (body.status === 413) {
      return yield* Effect.fail(new HandoffPayloadTooLargeError({}));
    }
    return yield* Effect.fail(new HandoffInvalidRequestError({}));
  });
}

function resolveContext(
  request: Request,
  dependencies: HandoffMintDependencies | HandoffExchangeDependencies,
): Effect.Effect<
  Awaited<ReturnType<typeof resolveCodeRouterRequestContext>> extends
    infer Result
    ? Result extends { readonly ok: true; readonly value: infer Value }
      ? Value
      : never
    : never,
  HandoffAuthorizationUnavailableError | HandoffResponseError
> {
  return tryPromise(
    () => dependencies.resolveContext(request, "use"),
    () => new HandoffAuthorizationUnavailableError({}),
  ).pipe(
    Effect.flatMap((resolved) =>
      resolved.ok
        ? Effect.succeed(resolved.value)
        : Effect.fail(new HandoffResponseError({
          response: resolved.response,
        })),
    ),
  );
}

function checkEntitlement(
  dependencies: HandoffMintDependencies | HandoffExchangeDependencies,
  userId: string,
  teamId: string,
): Effect.Effect<
  void,
  HandoffEntitlementRequiredError | HandoffEntitlementUnavailableError
> {
  return tryPromise(
    () => dependencies.hasActiveEntitlement(userId, teamId),
    () => new HandoffEntitlementUnavailableError({}),
  ).pipe(
    Effect.flatMap((active) =>
      active
        ? Effect.succeed(undefined)
        : Effect.fail(new HandoffEntitlementRequiredError({})),
    ),
  );
}

function mintAuthorizer(
  dependencies: HandoffMintDependencies,
): CodeRouterHandoffAuthorizer {
  return async (
    identity: { readonly teamId: string; readonly stackUserId: string },
    db: CodeRouterHandoffEntitlementDb,
  ) => {
    try {
      return await dependencies.hasActiveEntitlement(
        identity.stackUserId,
        identity.teamId,
        db,
      );
    } catch {
      throw new HandoffAuthorizerUnavailableError();
    }
  };
}

export function mintCoderouterHandoff(
  request: Request,
  dependencies: HandoffMintDependencies,
): Effect.Effect<HandoffMintResult, HandoffWorkflowError> {
  return Effect.gen(function* () {
    yield* rateLimit(request, dependencies.protocol);
    if (
      !dependencies.protocol.isBoundedNativeStackRequest(request) ||
      !dependencies.protocol.validTeamSelectorHeaders(request)
    ) {
      return yield* Effect.fail(new HandoffUnauthorizedError({}));
    }
    const body = yield* readHandoffBody(request, dependencies.protocol);
    if (
      body.trim() &&
      (
        !dependencies.protocol.isJsonContentType(request) ||
        !dependencies.protocol.parseEmptyHandoffBody(body)
      )
    ) {
      return yield* Effect.fail(new HandoffInvalidRequestError({}));
    }

    const resolved = yield* resolveContext(request, dependencies);
    if (!resolved.team.use) {
      return yield* Effect.fail(new HandoffForbiddenError({}));
    }
    const hostedProRequired = dependencies.hostedProRequired();
    if (hostedProRequired) {
      yield* checkEntitlement(
        dependencies,
        resolved.user.id,
        resolved.team.teamId,
      );
    }

    const now = dependencies.now?.() ?? new Date();
    const issued = yield* tryPromise(
      () =>
        hostedProRequired
          ? dependencies.issueLease(
            resolved.team.teamId,
            resolved.user.id,
            now,
            mintAuthorizer(dependencies),
          )
          : dependencies.issueLease(
            resolved.team.teamId,
            resolved.user.id,
            now,
          ),
      (cause) => {
        if (cause instanceof AccountDeletionMutationBlockedError) {
          return new HandoffAccountDeletionBlockedError({});
        }
        if (cause instanceof HandoffAuthorizerUnavailableError) {
          return new HandoffEntitlementUnavailableError({});
        }
        if (cause instanceof CodeRouterHandoffEntitlementDenied) {
          return new HandoffEntitlementRequiredError({});
        }
        reportCoderouterFailure("rds", cause, {
          operation: "issue_handoff_lease",
        });
        return new HandoffPersistenceError({ operation: "mint" });
      },
    );

    captureCoderouterEvent({
      event: "coderouter_handoff_lease_issued",
      userId: resolved.user.id,
      teamId: resolved.team.teamId,
      properties: { authorization_mode: "native_stack" },
    });
    addCoderouterBreadcrumb("handoff", "Handoff lease issued");
    return {
      ...issued,
      teamId: resolved.team.teamId,
      stackUserId: resolved.user.id,
    };
  });
}

export function exchangeCoderouterHandoff(
  request: Request,
  suppliedLease: string | undefined,
  dependencies: HandoffExchangeDependencies,
): Effect.Effect<HandoffExchangeResult, HandoffWorkflowError> {
  return Effect.gen(function* () {
    yield* rateLimit(request, dependencies.protocol);
    const body = yield* readHandoffBody(request, dependencies.protocol);
    if (!dependencies.protocol.isJsonContentType(request)) {
      return yield* Effect.fail(new HandoffInvalidRequestError({}));
    }
    const lease = dependencies.protocol.parseHandoffLeaseBody(body);
    if (!lease || (suppliedLease !== undefined && suppliedLease !== lease)) {
      return yield* Effect.fail(new HandoffInvalidRequestError({}));
    }
    const hostedProRequired = dependencies.hostedProRequired();
    let expectedIdentity: CodeRouterHandoffIdentity = {};

    if (
      !dependencies.protocol.hasNativeStackAuthHeaders(request) &&
      request.headers.get("cookie") !== null
    ) {
      return yield* Effect.fail(new HandoffUnauthorizedError({}));
    }

    if (dependencies.protocol.hasNativeStackAuthHeaders(request)) {
      if (
        !dependencies.protocol.isBoundedNativeStackRequest(request) ||
        !dependencies.protocol.validTeamSelectorHeaders(request)
      ) {
        return yield* Effect.fail(new HandoffUnauthorizedError({}));
      }
      const resolved = yield* resolveContext(request, dependencies);
      if (!resolved.team.use) {
        return yield* Effect.fail(new HandoffForbiddenError({}));
      }
      if (hostedProRequired) {
        yield* checkEntitlement(
          dependencies,
          resolved.user.id,
          resolved.team.teamId,
        );
      }
      expectedIdentity = {
        teamId: resolved.team.teamId,
        stackUserId: resolved.user.id,
      };
    } else if (
      !dependencies.protocol.validTeamSelectorHeaders(request) ||
      dependencies.protocol.hasTeamSelector(request)
    ) {
      return yield* Effect.fail(new HandoffInvalidRequestError({}));
    }

    const openaiBaseUrl = dependencies.protocol.coderouterOpenaiBaseUrl(
      request,
      dependencies.publicOrigin?.(),
    );
    if (!openaiBaseUrl) {
      reportCoderouterFailure("configuration", new Error("handoff origin unavailable"), {
        operation: "resolve_handoff_origin",
      });
      return yield* Effect.fail(new HandoffConfigurationError({}));
    }

    const authorize: CodeRouterHandoffAuthorizer | undefined =
      hostedProRequired
        ? async (
          identity,
          db: CodeRouterHandoffEntitlementDb,
        ) => {
          try {
            return await dependencies.hasActiveEntitlement(
              identity.stackUserId,
              identity.teamId,
              db,
            );
          } catch {
            throw new HandoffAuthorizerUnavailableError();
          }
        }
        : undefined;
    const exchanged = yield* tryPromise(
      () => dependencies.exchangeLease(
        lease,
        dependencies.now?.() ?? new Date(),
        expectedIdentity,
        authorize,
      ),
      (cause) => {
        if (cause instanceof HandoffAuthorizerUnavailableError) {
          return new HandoffEntitlementUnavailableError({});
        }
        reportCoderouterFailure("rds", cause, {
          operation: "exchange_handoff_lease",
        });
        return new HandoffPersistenceError({ operation: "exchange" });
      },
    );
    if (!exchanged) {
      captureCoderouterEvent({
        event: "coderouter_handoff_rejected",
        properties: {
          surface: "exchange",
          reason: "expired_or_consumed",
        },
      });
      return yield* Effect.fail(new HandoffInvalidLeaseError({}));
    }
    captureCoderouterEvent({
      event: "coderouter_handoff_lease_exchanged",
      userId: exchanged.stackUserId,
      teamId: exchanged.teamId,
      properties: {
        authorization_mode: Object.keys(expectedIdentity).length > 0
          ? "native_confirmation"
          : "lease",
      },
    });
    addCoderouterBreadcrumb("handoff", "Handoff lease exchanged");
    return { ...exchanged, openaiBaseUrl };
  });
}

export function makeHandoffWorkflow(
  dependencies: HandoffMintDependencies & HandoffExchangeDependencies,
): HandoffWorkflowShape {
  return {
    mint: (request) => mintCoderouterHandoff(request, dependencies),
    exchange: (request, lease) =>
      exchangeCoderouterHandoff(request, lease, dependencies),
  };
}

export function handoffWorkflowLayer(
  dependencies: HandoffMintDependencies & HandoffExchangeDependencies,
): Layer.Layer<HandoffWorkflow> {
  return Layer.succeed(HandoffWorkflow, makeHandoffWorkflow(dependencies));
}

export function mapHandoffWorkflowError(
  error: HandoffWorkflowError,
  json: (
    value: unknown,
    status?: number,
    headers?: Record<string, string>,
  ) => Response,
  rateLimitResponse: (
    outcome: Exclude<HandoffRateLimitOutcome, "allowed">,
  ) => Response | null,
): Response {
  if (error instanceof HandoffResponseError) return error.response;
  if (error instanceof HandoffRateLimitError) {
    return rateLimitResponse(error.outcome) ?? json(
      {
        error: "handoff_unavailable",
        message: "CodeRouter handoff is temporarily unavailable.",
        retryable: true,
      },
      503,
      { "retry-after": "5" },
    );
  }
  if (error instanceof HandoffUnauthorizedError) {
    return json({ error: "unauthorized" }, 401);
  }
  if (error instanceof HandoffInvalidRequestError) {
    return json({ error: "invalid_request" }, 400);
  }
  if (error instanceof HandoffPayloadTooLargeError) {
    return json({ error: "payload_too_large" }, 413);
  }
  if (error instanceof HandoffForbiddenError) {
    return json({ error: "forbidden" }, 403);
  }
  if (error instanceof HandoffEntitlementRequiredError) {
    return json({ error: "pro_required", retryable: false }, 402);
  }
  if (error instanceof HandoffAccountDeletionBlockedError) {
    return json(
      { error: "account_deletion_in_progress", retryable: false },
      409,
    );
  }
  if (error instanceof HandoffAuthorizationUnavailableError) {
    return json(
      {
        error: "authorization_unavailable",
        message: "CodeRouter authorization is temporarily unavailable.",
        retryable: true,
      },
      503,
      { "retry-after": "5" },
    );
  }
  if (error instanceof HandoffEntitlementUnavailableError) {
    return json(
      {
        error: "entitlement_unavailable",
        message: "CodeRouter entitlement could not be verified.",
        retryable: true,
      },
      503,
      { "retry-after": "5" },
    );
  }
  if (error instanceof HandoffConfigurationError) {
    return json(
      {
        error: "handoff_unavailable",
        message: "CodeRouter handoff could not be exchanged.",
        retryable: true,
      },
      503,
      { "retry-after": "5" },
    );
  }
  if (error instanceof HandoffInvalidLeaseError) {
    return json({ error: "invalid_handoff_lease", retryable: false }, 401);
  }
  return json(
    {
      error: "handoff_unavailable",
      message: "CodeRouter handoff could not be processed.",
      retryable: true,
    },
    503,
    { "retry-after": "5" },
  );
}

export async function runHandoffWorkflow<A>(
  program: Effect.Effect<A, HandoffWorkflowError>,
) {
  return await Effect.runPromise(Effect.either(program));
}
