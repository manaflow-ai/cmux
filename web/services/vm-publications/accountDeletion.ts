import { eq, sql } from "drizzle-orm";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import type { cloudDb } from "../../db/client";
import {
  cloudVmDomains,
  cloudVmPublicationAuthCodes,
  cloudVmPublications,
  cloudVmPublicationSessions,
} from "../../db/schema";
import {
  VmPublicationProvider,
  VmPublicationProviderLive,
} from "./provider";
import {
  CloudVmPublicationRepository,
  CloudVmPublicationRepositoryLive,
  type CloudVmPublicationAccountDeletionTarget,
} from "./repository";

type CloudDbTransaction =
  Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

export type VmPublicationAccountDeletionResult = {
  readonly publications: number;
  readonly providerRules: number;
};

export class VmPublicationAccountDeletionHookError extends Data.TaggedError(
  "VmPublicationAccountDeletionHookError",
)<{
  readonly operation: "beforePublicationTeardown" | "afterPublicationTeardown";
  readonly cause: unknown;
}> {}

export class VmPublicationAccountDeletionUnsupportedProviderError extends Data.TaggedError(
  "VmPublicationAccountDeletionUnsupportedProviderError",
)<{
  readonly provider: string;
}> {}

export type VmPublicationAccountDeletionOptions = {
  readonly ownerUserId: string;
  readonly now?: () => Date;
  readonly beforePublicationTeardown?: (
    target: CloudVmPublicationAccountDeletionTarget,
  ) => void | Promise<void>;
  readonly afterPublicationTeardown?: (
    target: CloudVmPublicationAccountDeletionTarget,
  ) => void | Promise<void>;
};

/**
 * Fail-closed external cleanup for account deletion.
 *
 * Every publication is disabled before any provider I/O, then all of their
 * exact-hostname rules are deleted with one provider listing. Sweeping by
 * hostname removes both the persisted rule and a duplicate left if a process
 * died between provider creation and DB commit. Rows are only marked
 * `disabled` after the sweep succeeds, so a provider failure keeps every
 * hostname on the next attempt's list.
 */
export function teardownVmPublicationsForAccountDeletion(
  input: VmPublicationAccountDeletionOptions,
) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const provider = yield* VmPublicationProvider;
    const targets = yield* repository.listPublicationsForAccountDeletion(
      input.ownerUserId,
    );
    const unsupported = targets.find((target) => target.provider !== "freestyle");
    if (unsupported) {
      return yield* new VmPublicationAccountDeletionUnsupportedProviderError({
        provider: unsupported.provider,
      });
    }
    const disabled: Array<{
      readonly target: CloudVmPublicationAccountDeletionTarget;
      readonly alreadyDisabled: boolean;
    }> = [];
    for (const target of targets) {
      yield* accountDeletionHook(
        "beforePublicationTeardown",
        () => input.beforePublicationTeardown?.(target),
      );
      const publication = yield* repository.beginDisablePublication({
        id: target.publicationId,
        ownerUserId: input.ownerUserId,
        now: input.now?.() ?? new Date(),
      });
      disabled.push({ target, alreadyDisabled: publication.state === "disabled" });
    }
    const providerRules = targets.length === 0
      ? 0
      : yield* provider.deleteTlsRulesForHostnames(
        targets.map((target) => target.hostname),
      );
    for (const { target, alreadyDisabled } of disabled) {
      if (!alreadyDisabled) {
        yield* repository.finishDisablePublication({
          id: target.publicationId,
          now: input.now?.() ?? new Date(),
        });
      }
      yield* accountDeletionHook(
        "afterPublicationTeardown",
        () => input.afterPublicationTeardown?.(target),
      );
    }
    return { publications: targets.length, providerRules };
  });
}

const VmPublicationAccountDeletionLive = Layer.merge(
  CloudVmPublicationRepositoryLive,
  VmPublicationProviderLive,
);

export async function deleteVmPublicationsForAccountDeletion(
  input: VmPublicationAccountDeletionOptions,
): Promise<VmPublicationAccountDeletionResult> {
  const result = await Effect.runPromise(
    teardownVmPublicationsForAccountDeletion(input).pipe(
      Effect.provide(VmPublicationAccountDeletionLive),
      Effect.either,
    ),
  );
  if (result._tag === "Left") throw result.left;
  return result.right;
}

/** Delete publications and viewer identity data, while retaining provider domain ownership. */
export async function deleteVmPublicationRowsForAccountDeletion(
  tx: CloudDbTransaction,
  userId: string,
): Promise<void> {
  await tx
    .delete(cloudVmPublicationSessions)
    .where(eq(cloudVmPublicationSessions.userId, userId));
  await tx
    .delete(cloudVmPublicationAuthCodes)
    .where(eq(cloudVmPublicationAuthCodes.userId, userId));
  await tx
    .delete(cloudVmPublications)
    .where(eq(cloudVmPublications.ownerUserId, userId));
  await tx
    .update(cloudVmDomains)
    .set({
      ownerUserId: sql<string>`'deleted-domain:' || ${cloudVmDomains.id}::text`,
      updatedAt: new Date(),
    })
    .where(eq(cloudVmDomains.ownerUserId, userId));
}

function accountDeletionHook(
  operation: VmPublicationAccountDeletionHookError["operation"],
  hook: () => void | Promise<void> | undefined,
): Effect.Effect<void, VmPublicationAccountDeletionHookError> {
  return Effect.tryPromise({
    try: async () => {
      await hook();
    },
    catch: (cause) => new VmPublicationAccountDeletionHookError({
      operation,
      cause,
    }),
  });
}
