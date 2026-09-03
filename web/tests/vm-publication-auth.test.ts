import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import {
  CloudVmPublicationRepository,
  type CloudVmPublicationRepositoryShape,
} from "../services/vm-publications/repository";
import {
  authorizePublicationRequest,
  completePublicationAuthorization,
  evaluatePublicationRequest,
  PublicationViewerResolver,
  resolvePublicationAccess,
  type PublicationViewerResolverShape,
} from "../services/vm-publications/auth";
import {
  hashPublicationToken,
  parsePublicationTransactionCookie,
  publicationPkceChallenge,
  randomPublicationToken,
} from "../services/vm-publications/security";

const now = new Date("2026-09-02T12:00:00.000Z");
const publication = {
  id: "publication-1",
  hostname: "preview.example.com",
  ownerUserId: "owner-1",
  accessMode: "personal" as const,
  teamId: null,
  routingRevision: 3,
  state: "active" as const,
  disabledAt: null,
};
const domain = { hostname: "example.com" };
const target = { publication, domain, vm: { providerVmId: "vm-1" } };

describe("Cloud VM publication auth exchange", () => {
  test("starts a PKCE-bound transaction and redirects only safe browser methods", async () => {
    const created: { current: Record<string, unknown> | null } = { current: null };
    const repository = authRepository({
      findActivePublicationForRequest: () => Effect.succeed(target as never),
      createAuthTransaction: (input) => {
        created.current = input as unknown as Record<string, unknown>;
        return Effect.succeed(input as never);
      },
    });

    const authorize = (method: string) => run(
      authorizePublicationRequest({
        hostname: publication.hostname,
        providerTlsRuleId: "tls-rule-1",
        method,
        returnPath: "/editor?file=one",
        sessionToken: null,
        authPageOrigin: "https://cmux.com",
        now,
      }),
      repository,
    );

    const decision = await authorize("GET");
    expect(decision.kind).toBe("redirect");
    if (decision.kind !== "redirect") throw new Error("expected an auth transaction");
    const location = new URL(decision.location);
    const transaction = location.searchParams.get("transaction");
    const state = location.searchParams.get("state");
    const cookie = parsePublicationTransactionCookie(decision.transactionCookie);
    expect(location.origin).toBe("https://cmux.com");
    expect(location.pathname).toBe("/cloud/access");
    expect(cookie?.transaction).toBe(transaction);
    const captured = created.current as unknown as Record<string, unknown>;
    expect(captured.transactionHash).toBe(hashPublicationToken(transaction!));
    expect(captured.stateHash).toBe(hashPublicationToken(state!));
    expect(captured.pkceChallenge).toBe(
      publicationPkceChallenge(cookie!.verifier),
    );
    expect(captured.hostname).toBe(publication.hostname);
    expect(captured.returnPath).toBe("/editor?file=one");

    // A request that cannot follow a redirect is refused without minting a
    // transaction, so scripted traffic never grows the auth tables.
    for (const method of ["POST", "PUT", "PATCH", "DELETE", "OPTIONS", "head "]) {
      created.current = null;
      const refused = await authorize(method);
      expect(refused).toEqual(
        method.trim().toUpperCase() === "HEAD"
          ? expect.objectContaining({ kind: "redirect" })
          : { kind: "unauthorized" },
      );
      if (method.trim().toUpperCase() !== "HEAD") expect(created.current).toBeNull();
    }
  });

  test("evaluation reports that sign-in is required without minting a transaction", async () => {
    const repository = authRepository({
      findActivePublicationForRequest: () => Effect.succeed(target as never),
      createAuthTransaction: () => Effect.die("evaluation must not write"),
    });
    const evaluation = await run(
      evaluatePublicationRequest({
        hostname: publication.hostname,
        providerTlsRuleId: "tls-rule-1",
        method: "GET",
        sessionToken: null,
        now,
      }),
      repository,
    );
    expect(evaluation).toEqual({ kind: "sign_in_required", target });
  });

  test("allows a personal session without enumerating teams and rechecks team membership", async () => {
    const sessionToken = randomPublicationToken();
    let transactionCreated = false;
    const personalRepository = authRepository({
      findActivePublicationForRequest: () => Effect.succeed(target as never),
      findValidSession: () => Effect.succeed({
        session: { userId: publication.ownerUserId },
        publication,
        domain,
      } as never),
      createAuthTransaction: () => {
        transactionCreated = true;
        return Effect.die("unexpected transaction");
      },
    });
    const allowed = await run(
      authorizePublicationRequest({
        hostname: publication.hostname,
        providerTlsRuleId: "tls-rule-1",
        method: "GET",
        returnPath: "/",
        sessionToken,
        authPageOrigin: "https://cmux.com",
        now,
      }),
      personalRepository,
      { resolve: () => Effect.die("personal sessions must not enumerate Stack teams") },
    );
    expect(allowed).toEqual({ kind: "allow" });
    expect(transactionCreated).toBe(false);

    const teamPublication = {
      ...publication,
      accessMode: "team" as const,
      teamId: "team-1",
    };
    const teamRepository = authRepository({
      findActivePublicationForRequest: () => Effect.succeed({
        ...target,
        publication: teamPublication,
      } as never),
      findValidSession: () => Effect.succeed({
        session: { userId: "viewer-1" },
        publication: teamPublication,
        domain,
      } as never),
      createAuthTransaction: (input) => Effect.succeed(input as never),
    });
    const revoked = await run(
      authorizePublicationRequest({
        hostname: publication.hostname,
        providerTlsRuleId: "tls-rule-1",
        method: "GET",
        returnPath: "/",
        sessionToken,
        authPageOrigin: "https://cmux.com",
        now,
      }),
      teamRepository,
      { resolve: () => Effect.succeed({ userId: "viewer-1", teamIds: [] }) },
    );
    expect(revoked.kind).toBe("redirect");
  });

  test("turns an authorized CMUX account into a one-time callback code", async () => {
    const transaction = randomPublicationToken();
    const state = randomPublicationToken();
    const issued: { current: Record<string, unknown> | null } = { current: null };
    const pending = {
      transaction: {
        transactionHash: hashPublicationToken(transaction),
        stateHash: hashPublicationToken(state),
      },
      publication,
      domain,
    };
    const repository = authRepository({
      findPendingAuthTransaction: () => Effect.succeed(pending as never),
      issueAuthCode: (input) => {
        issued.current = input as unknown as Record<string, unknown>;
        return Effect.succeed({ code: {}, transaction: {} } as never);
      },
    });

    const resolution = await run(
      resolvePublicationAccess({
        transaction,
        state,
        user: { userId: "owner-1", teamIds: [], identity: "owner@example.com" },
        now,
      }),
      repository,
    );
    expect(resolution.kind).toBe("authorized");
    if (resolution.kind !== "authorized") throw new Error("expected callback");
    const callback = new URL(resolution.callbackUrl);
    expect(callback.origin).toBe("https://preview.example.com");
    expect(callback.pathname).toBe("/_cmux/auth/callback");
    expect(callback.searchParams.get("state")).toBe(state);
    expect(issued.current?.transactionHash).toBe(hashPublicationToken(transaction));
    expect(issued.current?.codeHash).toBe(
      hashPublicationToken(callback.searchParams.get("code")!),
    );
  });

  test("always refreshes current team membership before the CMUX handoff", async () => {
    const transaction = randomPublicationToken();
    const state = randomPublicationToken();
    const teamPublication = {
      ...publication,
      accessMode: "team" as const,
      teamId: "team-1",
    };
    const pending = {
      transaction: {
        transactionHash: hashPublicationToken(transaction),
        stateHash: hashPublicationToken(state),
      },
      publication: teamPublication,
      domain,
    };
    const repository = authRepository({
      findPendingAuthTransaction: () => Effect.succeed(pending as never),
      issueAuthCode: () => Effect.succeed({ code: {}, transaction: {} } as never),
    });
    const addedMember = await run(
      resolvePublicationAccess({
        transaction,
        state,
        user: { userId: "viewer-1", teamIds: [], identity: "viewer@example.com" },
        now,
      }),
      repository,
      {
        resolve: () => Effect.succeed({
          userId: "viewer-1",
          teamIds: ["team-1"],
        }),
      },
    );
    expect(addedMember.kind).toBe("authorized");

    const removedMember = await run(
      resolvePublicationAccess({
        transaction,
        state,
        user: {
          userId: "viewer-1",
          teamIds: ["team-1"],
          identity: "viewer@example.com",
        },
        now,
      }),
      repository,
      {
        resolve: () => Effect.succeed({
          userId: "viewer-1",
          teamIds: [],
        }),
      },
    );
    expect(removedMember.kind).toBe("denied");
  });

  test("exchanges the callback code and PKCE verifier for a raw browser session", async () => {
    const code = randomPublicationToken();
    const state = randomPublicationToken();
    const transaction = randomPublicationToken();
    const verifier = randomPublicationToken();
    const consumed: { current: Record<string, unknown> | null } = { current: null };
    const repository = authRepository({
      consumeAuthCodeAndCreateSession: (input) => {
        consumed.current = input as unknown as Record<string, unknown>;
        return Effect.succeed({
          session: {},
          publication,
          returnPath: "/editor",
        } as never);
      },
    });
    const result = await run(
      completePublicationAuthorization({
        hostname: publication.hostname,
        code,
        state,
        transaction,
        verifier,
        now,
      }),
      repository,
    );
    expect(result.kind).toBe("complete");
    if (result.kind !== "complete") throw new Error("expected session");
    expect(result.returnPath).toBe("/editor");
    expect(consumed.current?.codeHash).toBe(hashPublicationToken(code));
    expect(consumed.current?.stateHash).toBe(hashPublicationToken(state));
    expect(consumed.current?.pkceChallenge).toBe(publicationPkceChallenge(verifier));
    expect(consumed.current?.sessionTokenHash).toBe(
      hashPublicationToken(result.sessionToken),
    );
  });
});

function authRepository(
  overrides: Partial<CloudVmPublicationRepositoryShape>,
): CloudVmPublicationRepositoryShape {
  return overrides as CloudVmPublicationRepositoryShape;
}

async function run<A, E, R>(
  program: Effect.Effect<A, E, R>,
  repository: CloudVmPublicationRepositoryShape,
  viewerResolver: PublicationViewerResolverShape = {
    resolve: (userId) => Effect.succeed({ userId, teamIds: [] }),
  },
): Promise<A> {
  const runtime = Layer.merge(
    Layer.succeed(CloudVmPublicationRepository, repository),
    Layer.succeed(PublicationViewerResolver, viewerResolver),
  );
  return Effect.runPromise(
    program.pipe(Effect.provide(runtime as Layer.Layer<R>)),
  );
}
