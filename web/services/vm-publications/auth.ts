import * as Context from "effect/Context";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { getStackServerApp } from "../../app/lib/stack";
import {
  CloudVmPublicationRepository,
  CloudVmPublicationRepositoryLive,
  type CloudVmPublicationAuthTransaction,
  type CloudVmPublicationTarget,
} from "./repository";
import {
  type VmPublicationPolicy,
  type VmPublicationViewer,
  vmPublicationAllowsViewer,
  publicationOwningTeamId,
} from "./policy";
import {
  PUBLICATION_CALLBACK_PATH,
  hashPublicationToken,
  isPublicationToken,
  normalizePublicationAuthOrigin,
  publicationPkceChallenge,
  publicationTransactionCookieValue,
  randomPublicationToken,
} from "./security";
import { normalizePublicationEmail } from "./managedHostnames";

export const PUBLICATION_TRANSACTION_TTL_MS = 10 * 60 * 1_000;
export const PUBLICATION_AUTH_CODE_TTL_MS = 60 * 1_000;
export const PUBLICATION_SESSION_TTL_MS = 12 * 60 * 60 * 1_000;

export class PublicationIdentityError extends Data.TaggedError(
  "PublicationIdentityError",
)<{
  readonly operation: string;
  readonly cause: unknown;
}> {}

export type PublicationViewerResolverShape = {
  readonly resolve: (
    userId: string,
  ) => Effect.Effect<VmPublicationViewer | null, PublicationIdentityError>;
};

export class PublicationViewerResolver extends Context.Tag(
  "cmux/PublicationViewerResolver",
)<PublicationViewerResolver, PublicationViewerResolverShape>() {}

export const PublicationViewerResolverLive = Layer.succeed(
  PublicationViewerResolver,
  {
    resolve: (userId) =>
      Effect.tryPromise({
        try: async () => {
          const user = await getStackServerApp().getUser(userId);
          if (!user) return null;
          const teamIds: string[] = [];
          const seenCursors = new Set<string>();
          let cursor: string | undefined;
          for (let page = 0; page < 100; page++) {
            const teams = await user.listTeams({ cursor, limit: 100 });
            teamIds.push(...teams.map((team) => team.id));
            const nextCursor = teams.nextCursor?.trim();
            if (!nextCursor) {
              return {
                userId: user.id, teamIds,
                verifiedEmails: user.primaryEmailVerified && user.primaryEmail
                  ? [user.primaryEmail.toLowerCase()] : [],
              };
            }
            if (seenCursors.has(nextCursor)) {
              throw new Error("Stack team pagination repeated a cursor");
            }
            seenCursors.add(nextCursor);
            cursor = nextCursor;
          }
          throw new Error("Stack team pagination exceeded its page limit");
        },
        catch: (cause) => new PublicationIdentityError({
          operation: "resolvePublicationViewer",
          cause,
        }),
      }),
  },
);

export const PublicationAuthRuntime = Layer.merge(
  CloudVmPublicationRepositoryLive,
  PublicationViewerResolverLive,
);

export function runPublicationAuth<A, E>(
  program: Effect.Effect<A, E, CloudVmPublicationRepository | PublicationViewerResolver>,
): Promise<A> {
  return Effect.runPromise(
    program.pipe(Effect.provide(PublicationAuthRuntime), Effect.either),
  ).then((result) => {
    if (result._tag === "Left") throw result.left;
    return result.right;
  });
}

export type ForwardAuthorizationDecision =
  | { readonly kind: "allow" }
  | {
    readonly kind: "redirect";
    readonly location: string;
    readonly transactionCookie: string;
  }
  /** No sign-in handoff is minted: the request cannot be replayed through a browser redirect. */
  | { readonly kind: "unauthorized" }
  | { readonly kind: "not_found" };

export type PublicationAccessUser = VmPublicationViewer & {
  readonly identity: string | null;
};

export type PublicationAccessResolution =
  | { readonly kind: "invalid" }
  | {
    readonly kind: "signed_out";
    readonly transaction: CloudVmPublicationAuthTransaction;
  }
  | {
    readonly kind: "authorized";
    readonly callbackUrl: string;
  }
  | {
    readonly kind: "denied";
    readonly transaction: CloudVmPublicationAuthTransaction;
    readonly user: PublicationAccessUser;
  };

export type PublicationRequestEvaluation =
  | { readonly kind: "allow" }
  | { readonly kind: "not_found" }
  | { readonly kind: "unauthorized" }
  /** No usable session and a navigable request: the caller may mint a sign-in transaction. */
  | { readonly kind: "sign_in_required"; readonly target: CloudVmPublicationTarget };

/**
 * Evaluate an edge-authenticated request against the current publication and
 * current Stack team membership without writing anything. The untrusted VM
 * never receives either cmux cookie; Freestyle keeps both in protectedCookies.
 * Minting the sign-in transaction is a separate step so the route can rate
 * limit it: every unauthenticated navigation would otherwise cost a write.
 */
export function evaluatePublicationRequest(input: {
  readonly providerTlsRuleId: string;
  readonly method: string;
  readonly sessionToken: string | null;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const viewerResolver = yield* PublicationViewerResolver;
    const target = yield* resolvePublicationForRequest(input);
    if (!target) return { kind: "not_found" } as const satisfies PublicationRequestEvaluation;

    if (target.publication.accessMode === "public") {
      // This can occur briefly during the fail-open-safe half of a protected ->
      // public transition, before the provider detaches forward auth.
      return { kind: "allow" } as const satisfies PublicationRequestEvaluation;
    }

    if (isPublicationToken(input.sessionToken)) {
      const principal = yield* repository.findValidSession({
        tokenHash: hashPublicationToken(input.sessionToken),
        publicationId: target.publication.id,
        hostname: target.publication.hostname,
        now: input.now ?? new Date(),
      });
      if (principal) {
        const owningTeamId = publicationOwningTeamId(target.vm);
        // Only the owner of a personal VM can skip the identity lookup. Team
        // VM ownership and email grants depend on current Stack identity.
        const viewer: VmPublicationViewer | null =
          owningTeamId !== null || principal.publication.accessMode === "team" || principal.session.userId !== principal.publication.ownerUserId
            ? yield* viewerResolver.resolve(principal.session.userId)
            : { userId: principal.session.userId, teamIds: [] };
        if (yield* publicationAllowsViewer(principal.publication, viewer, input.now ?? new Date(), owningTeamId)) {
          return { kind: "allow" } as const satisfies PublicationRequestEvaluation;
        }
      }
    }

    // Only a top-level browser navigation can complete the sign-in handoff.
    // Other methods fail without minting a transaction a browser could never
    // finish, so a scripted caller cannot grow the auth tables per request.
    if (!isRedirectableMethod(input.method)) {
      return { kind: "unauthorized" } as const satisfies PublicationRequestEvaluation;
    }
    return { kind: "sign_in_required", target } as const satisfies PublicationRequestEvaluation;
  });
}

/**
 * The publication a Freestyle forward-auth call is about, or null when no
 * active, reachable publication owns that TLS rule. Both the policy check and
 * the callback exchange start here so every hostname the route acts on comes
 * from the publication row, never from a forwarding header.
 */
export function resolvePublicationForRequest(input: {
  readonly providerTlsRuleId: string;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    return yield* repository.findActivePublicationForRequest({
      providerTlsRuleId: input.providerTlsRuleId,
    });
  });
}

/** Evaluate and, when sign-in is required, mint the transaction in one step. */
export function authorizePublicationRequest(input: {
  readonly providerTlsRuleId: string;
  readonly method: string;
  readonly returnPath: string;
  readonly sessionToken: string | null;
  readonly authPageOrigin: string;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const evaluation = yield* evaluatePublicationRequest(input);
    if (evaluation.kind !== "sign_in_required") return evaluation;
    return yield* beginPublicationAuthorization({
      target: evaluation.target,
      returnPath: input.returnPath,
      authPageOrigin: input.authPageOrigin,
      now: input.now ?? new Date(),
    });
  });
}

/** Complete the callback on the publication origin and mint a revision-bound session. */
export function completePublicationAuthorization(input: {
  readonly hostname: string;
  readonly code: string;
  readonly state: string;
  readonly transaction: string;
  readonly verifier: string;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    if (
      !isPublicationToken(input.code) ||
      !isPublicationToken(input.state) ||
      !isPublicationToken(input.transaction) ||
      !isPublicationToken(input.verifier)
    ) {
      return { kind: "invalid" } as const;
    }
    const repository = yield* CloudVmPublicationRepository;
    const now = input.now ?? new Date();
    const sessionToken = randomPublicationToken();
    const consumed = yield* repository.consumeAuthCodeAndCreateSession({
      codeHash: hashPublicationToken(input.code),
      transactionHash: hashPublicationToken(input.transaction),
      stateHash: hashPublicationToken(input.state),
      pkceChallenge: publicationPkceChallenge(input.verifier),
      hostname: input.hostname,
      sessionTokenHash: hashPublicationToken(sessionToken),
      now,
      sessionExpiresAt: new Date(now.getTime() + PUBLICATION_SESSION_TTL_MS),
    });
    return {
      kind: "complete",
      sessionToken,
      returnPath: consumed.returnPath,
    } as const;
  });
}

/** Resolve CMUX's browser page, issuing a one-time callback code when authorized. */
export function resolvePublicationAccess(input: {
  readonly transaction: string;
  readonly state: string;
  readonly user: PublicationAccessUser | null;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    if (!isPublicationToken(input.transaction) || !isPublicationToken(input.state)) {
      return { kind: "invalid" } as const;
    }
    const repository = yield* CloudVmPublicationRepository;
    const now = input.now ?? new Date();
    const pending = yield* repository.findPendingAuthTransaction({
      transactionHash: hashPublicationToken(input.transaction),
      now,
    });
    if (!pending || pending.transaction.stateHash !== hashPublicationToken(input.state)) {
      return { kind: "invalid" } as const;
    }
    if (!input.user) {
      return { kind: "signed_out", transaction: pending } as const;
    }
    const owningTeamId = publicationOwningTeamId(pending.vm);
    const currentViewer = yield* currentPublicationViewer(
      pending.publication,
      input.user,
      owningTeamId,
    );
    if (yield* publicationAllowsViewer(pending.publication, currentViewer, now, owningTeamId)) {
      const code = randomPublicationToken();
      yield* repository.issueAuthCode({
        transactionHash: pending.transaction.transactionHash,
        stateHash: hashPublicationToken(input.state),
        codeHash: hashPublicationToken(code),
        userId: input.user.userId,
        now,
        expiresAt: new Date(now.getTime() + PUBLICATION_AUTH_CODE_TTL_MS),
      });
      const callback = new URL(
        PUBLICATION_CALLBACK_PATH,
        `https://${pending.publication.hostname}`,
      );
      callback.searchParams.set("code", code);
      callback.searchParams.set("state", input.state);
      return { kind: "authorized", callbackUrl: callback.toString() } as const;
    }

    return {
      kind: "denied",
      transaction: pending,
      user: input.user,
    } as const;
  });
}

function currentPublicationViewer(
  publication: VmPublicationPolicy,
  user: PublicationAccessUser,
  owningTeamId: string | null,
) {
  return Effect.gen(function* () {
    if (publication.accessMode === "public" || (owningTeamId === null && publication.accessMode === "personal" && user.userId === publication.ownerUserId)) {
      return user;
    }
    // Team access is dynamic. Never trust the membership snapshot carried by
    // the CMUX page request: a removed member must lose access immediately,
    // just as a newly-added member must gain it without another sign-in.
    const resolver = yield* PublicationViewerResolver;
    const fresh = yield* resolver.resolve(user.userId);
    return fresh
      ? { ...user, teamIds: fresh.teamIds, verifiedEmails: fresh.verifiedEmails ?? [] }
      : { ...user, teamIds: [], verifiedEmails: [] };
  });
}

/** Grants are read on each request, so deletion and expiry apply to existing sessions. */
function publicationAllowsViewer(publication: VmPublicationPolicy & { readonly id: string }, viewer: VmPublicationViewer | null, now: Date, owningTeamId: string | null) {
  return Effect.gen(function* () {
    if (vmPublicationAllowsViewer(publication, viewer, owningTeamId)) return true;
    if (!viewer) return false;
    const repository = yield* CloudVmPublicationRepository;
    for (const value of viewer.verifiedEmails ?? []) {
      const email = normalizePublicationEmail(value);
      if (email && (yield* repository.hasEmailGrant({ publicationId: publication.id, email, now }))) return true;
    }
    return false;
  });
}

/** Mint the PKCE-bound sign-in transaction and the redirect that carries it. */
export function beginPublicationAuthorization(input: {
  readonly target: CloudVmPublicationTarget;
  readonly returnPath: string;
  readonly authPageOrigin: string;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const transaction = randomPublicationToken();
    const state = randomPublicationToken();
    const verifier = randomPublicationToken();
    const now = input.now ?? new Date();
    yield* repository.createAuthTransaction({
      publicationId: input.target.publication.id,
      transactionHash: hashPublicationToken(transaction),
      pkceChallenge: publicationPkceChallenge(verifier),
      stateHash: hashPublicationToken(state),
      hostname: input.target.publication.hostname,
      returnPath: input.returnPath,
      now,
      expiresAt: new Date(now.getTime() + PUBLICATION_TRANSACTION_TTL_MS),
    });
    const location = new URL("/cloud/access", normalizedAuthPageOrigin(input.authPageOrigin));
    location.searchParams.set("transaction", transaction);
    location.searchParams.set("state", state);
    return {
      kind: "redirect",
      location: location.toString(),
      transactionCookie: publicationTransactionCookieValue(transaction, verifier),
    } as const;
  });
}

function normalizedAuthPageOrigin(value: string): string {
  const origin = normalizePublicationAuthOrigin(value);
  if (!origin) {
    throw new Error("Publication auth page origin must be an HTTPS origin");
  }
  return origin;
}

/** Top-level browser navigations are the only requests a sign-in redirect can finish. */
export function isRedirectableMethod(method: string): boolean {
  const normalized = method.trim().toUpperCase();
  return normalized === "GET" || normalized === "HEAD";
}
