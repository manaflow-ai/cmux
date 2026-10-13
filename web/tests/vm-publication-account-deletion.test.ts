import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { teardownVmPublicationsForAccountDeletion } from "../services/vm-publications/accountDeletion";
import { ingressRule, publicationRuleStore } from "./fixtures/publicationRuleStore";
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
  providerVmId: "vm-1",
  hostnameClaimed: true,
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
          deletePublicationTlsRules: (publications) => {
            events.push(`delete:${publications.map((publication) => publication.hostname).join(",")}`);
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
            deletePublicationTlsRules: () => {
              events.push("provider-delete");
              return Effect.fail(
                new VmPublicationProviderError({
                  operation: "deletePublicationTlsRules",
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
        operation: "deletePublicationTlsRules",
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
      providerVmId: "vm-1",
      hostnameClaimed: true,
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
          deletePublicationTlsRules: (publications) => {
            events.push(`delete:${publications.map((publication) => publication.hostname).join(",")}`);
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

  test("removes the account's own rules and never a claimed owner's rule on the same hostname", async () => {
    const store = publicationRuleStore([
      ingressRule("tls-foreign-owner", "app.example.com", "vm-foreign"),
      ingressRule("tls-own", "app.example.com", "vm-a"),
      ingressRule("tls-own-duplicate", "app.example.com", "vm-a"),
    ]);
    const claimed = { ...TARGET, publicationId: "00000000-0000-4000-8000-00000000000a", hostname: "app.example.com", providerVmId: "vm-a" };
    const unclaimed = { ...TARGET, publicationId: "00000000-0000-4000-8000-00000000000b", hostname: "app.example.com", providerVmId: "vm-b", providerTlsRuleId: null, hostnameClaimed: false };
    // The first listing is stale: the claimed row recorded its rule after it.
    const listed = [{ ...claimed, providerTlsRuleId: null }, unclaimed];
    const rows = new Map([
      [claimed.publicationId, { id: claimed.publicationId, state: "disabling", providerTlsRuleId: "tls-own", hostnameClaimedAt: new Date() }],
      [unclaimed.publicationId, { id: unclaimed.publicationId, state: "disabling", providerTlsRuleId: null, hostnameClaimedAt: null }],
    ]);
    const result = await Effect.runPromise(runTeardown({
      repository: {
        listPublicationsForAccountDeletion: () => Effect.succeed(listed),
        beginDisablePublication: (input) => Effect.succeed(rows.get(input.id) as never),
        finishDisablePublication: () => Effect.succeed({ state: "disabled" } as never),
      },
      provider: store.provider,
    }));
    expect(result.publications).toBe(2);
    expect(store.rules.map((rule) => rule.id)).toEqual(["tls-foreign-owner"]);
    expect([...store.deleted].sort()).toEqual(["tls-own", "tls-own-duplicate"]);
  });
});
