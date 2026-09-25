import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { teardownVmPublicationsForAccountDeletion } from "../services/vm-publications/accountDeletion";
import {
  VmPublicationProvider,
  VmPublicationProviderError,
  type VmPublicationProviderShape,
} from "../services/vm-publications/provider";
import {
  CloudVmPublicationRepository,
  type CloudVmPublicationAccountDeletionTarget,
  type CloudVmPublicationRepositoryShape,
} from "../services/vm-publications/repository";

const TARGET: CloudVmPublicationAccountDeletionTarget = {
  publicationId: "00000000-0000-4000-8000-000000000001",
  provider: "freestyle",
  hostname: "account.preview.example.test",
  providerTlsRuleId: "tls-rule-account",
};

function runTeardown(input: {
  readonly repository: Partial<CloudVmPublicationRepositoryShape>;
  readonly provider: Partial<VmPublicationProviderShape>;
  readonly beforePublicationTeardown?: () => void;
  readonly afterPublicationTeardown?: () => void;
}) {
  return teardownVmPublicationsForAccountDeletion({
    ownerUserId: "owner-account",
    now: () => new Date("2026-09-02T20:00:00.000Z"),
    beforePublicationTeardown: input.beforePublicationTeardown,
    afterPublicationTeardown: input.afterPublicationTeardown,
  }).pipe(
    Effect.provide(
      Layer.merge(
        Layer.succeed(
          CloudVmPublicationRepository,
          input.repository as CloudVmPublicationRepositoryShape,
        ),
        Layer.succeed(
          VmPublicationProvider,
          input.provider as VmPublicationProviderShape,
        ),
      ),
    ),
  );
}

describe("VM publication account deletion", () => {
  test("disables a publication, sweeps its exact hostname, then completes teardown", async () => {
    const events: string[] = [];
    const result = await Effect.runPromise(
      runTeardown({
        repository: {
          listPublicationsForAccountDeletion: () => {
            events.push("list");
            return Effect.succeed([TARGET]);
          },
          beginDisablePublication: () => {
            events.push("begin-disable");
            return Effect.succeed({ state: "disabling" } as never);
          },
          finishDisablePublication: () => {
            events.push("finish-disable");
            return Effect.succeed({ state: "disabled" } as never);
          },
        },
        provider: {
          deleteTlsRulesForHostnames: (hostnames) => {
            events.push(`delete:${hostnames.join(",")}`);
            return Effect.succeed(2);
          },
        },
        beforePublicationTeardown: () => events.push("before"),
        afterPublicationTeardown: () => events.push("after"),
      }),
    );

    expect(result).toEqual({ publications: 1, providerRules: 2 });
    expect(events).toEqual([
      "list",
      "before",
      "begin-disable",
      "delete:account.preview.example.test",
      "finish-disable",
      "after",
    ]);
  });

  test("fails closed without completing DB teardown after an ambiguous provider failure", async () => {
    const events: string[] = [];
    const result = await Effect.runPromise(
      Effect.either(
        runTeardown({
          repository: {
            listPublicationsForAccountDeletion: () => Effect.succeed([TARGET]),
            beginDisablePublication: () => {
              events.push("begin-disable");
              return Effect.succeed({ state: "disabling" } as never);
            },
            finishDisablePublication: () => {
              events.push("finish-disable");
              return Effect.succeed({ state: "disabled" } as never);
            },
          },
          provider: {
            deleteTlsRulesForHostnames: () => {
              events.push("provider-delete");
              return Effect.fail(
                new VmPublicationProviderError({
                  operation: "deleteTlsRulesForHostnames",
                  cause: new Error("provider unavailable"),
                }),
              );
            },
          },
          afterPublicationTeardown: () => events.push("after"),
        }),
      ),
    );

    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left).toMatchObject({
        _tag: "VmPublicationProviderError",
        operation: "deleteTlsRulesForHostnames",
      });
    }
    expect(events).toEqual(["begin-disable", "provider-delete"]);
  });

  test("disables every publication first, then sweeps all hostnames with one provider listing", async () => {
    const events: string[] = [];
    const second: CloudVmPublicationAccountDeletionTarget = {
      ...TARGET,
      publicationId: "00000000-0000-4000-8000-000000000002",
      hostname: "second.preview.example.test",
      providerTlsRuleId: null,
    };
    const result = await Effect.runPromise(
      runTeardown({
        repository: {
          listPublicationsForAccountDeletion: () => Effect.succeed([TARGET, second]),
          beginDisablePublication: (input) => {
            events.push(`begin:${input.id}`);
            return Effect.succeed({ state: "disabling" } as never);
          },
          finishDisablePublication: (input) => {
            events.push(`finish:${input.id}`);
            return Effect.succeed({ state: "disabled" } as never);
          },
        },
        provider: {
          deleteTlsRulesForHostnames: (hostnames) => {
            events.push(`delete:${hostnames.join(",")}`);
            return Effect.succeed(3);
          },
        },
      }),
    );

    expect(result).toEqual({ publications: 2, providerRules: 3 });
    expect(events).toEqual([
      `begin:${TARGET.publicationId}`,
      `begin:${second.publicationId}`,
      "delete:account.preview.example.test,second.preview.example.test",
      `finish:${TARGET.publicationId}`,
      `finish:${second.publicationId}`,
    ]);
  });
});
