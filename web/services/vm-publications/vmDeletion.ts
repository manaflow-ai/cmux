import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import {
  VmPublicationProvider,
  VmPublicationProviderLive,
} from "./provider";
import {
  CloudVmPublicationRepository,
  CloudVmPublicationRepositoryLive,
} from "./repository";
import { PublicationProvisioningBusyError } from "./workflows";

export class VmPublicationDeletionUnsupportedProviderError extends Data.TaggedError(
  "VmPublicationDeletionUnsupportedProviderError",
)<{
  readonly provider: string;
}> {}

export type VmPublicationDeletionInput = {
  readonly requesterUserId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds: readonly string[];
  readonly providerVmId: string;
  readonly now?: Date;
};

export type VmPublicationDeletionResult = {
  readonly publications: number;
  readonly providerRules: number;
};

/**
 * Permanently freeze publication creation for a VM, then remove all live
 * ingress before the provider VM can be destroyed. An unexpired publication
 * operation lease makes the caller retry while the freeze remains durable.
 */
export function teardownVmPublicationsForVmDeletion(
  input: VmPublicationDeletionInput,
) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const provider = yield* VmPublicationProvider;
    const now = input.now ?? new Date();
    const freeze = yield* repository.freezeVmPublicationsForDeletion({
      requesterUserId: input.requesterUserId,
      billingTeamId: input.billingTeamId,
      teamIds: input.teamIds,
      providerVmId: input.providerVmId,
      now,
    });
    if (freeze.kind === "in_progress") {
      return yield* new PublicationProvisioningBusyError({
        retryAt: freeze.retryAt,
      });
    }

    let providerRules = 0;
    for (const publication of freeze.publications) {
      if (publication.provider !== "freestyle") {
        return yield* new VmPublicationDeletionUnsupportedProviderError({
          provider: publication.provider,
        });
      }
      providerRules += yield* provider.deleteTlsRulesForHostname(
        publication.hostname,
      );
      yield* repository.finishDisablePublication({
        id: publication.publicationId,
        now,
      });
    }
    return {
      publications: freeze.publications.length,
      providerRules,
    };
  });
}

const VmPublicationVmDeletionLive = Layer.merge(
  CloudVmPublicationRepositoryLive,
  VmPublicationProviderLive,
);

export async function deleteVmPublicationsForVmDeletion(
  input: VmPublicationDeletionInput,
): Promise<VmPublicationDeletionResult> {
  const result = await Effect.runPromise(
    teardownVmPublicationsForVmDeletion(input).pipe(
      Effect.provide(VmPublicationVmDeletionLive),
      Effect.either,
    ),
  );
  if (result._tag === "Left") throw result.left;
  return result.right;
}
