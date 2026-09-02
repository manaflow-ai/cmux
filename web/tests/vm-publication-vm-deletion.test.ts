import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import {
  VmPublicationProvider,
  VmPublicationProviderError,
  type VmPublicationProviderShape,
} from "../services/vm-publications/provider";
import {
  CloudVmPublicationRepository,
  type CloudVmPublicationRepositoryShape,
} from "../services/vm-publications/repository";
import { teardownVmPublicationsForVmDeletion } from "../services/vm-publications/vmDeletion";

function runTeardown(input: {
  readonly repository: Partial<CloudVmPublicationRepositoryShape>;
  readonly provider?: Partial<VmPublicationProviderShape>;
}) {
  return teardownVmPublicationsForVmDeletion({
    requesterUserId: "user-1",
    billingTeamId: "team-1",
    teamIds: ["team-1"],
    providerVmId: "provider-vm-1",
    now: new Date("2026-09-02T21:00:00.000Z"),
  }).pipe(
    Effect.provide(
      Layer.merge(
        Layer.succeed(
          CloudVmPublicationRepository,
          input.repository as CloudVmPublicationRepositoryShape,
        ),
        Layer.succeed(
          VmPublicationProvider,
          (input.provider ?? {}) as VmPublicationProviderShape,
        ),
      ),
    ),
  );
}

describe("VM deletion publication teardown", () => {
  test("sweeps and disables every live publication before returning", async () => {
    const events: string[] = [];
    const result = await Effect.runPromise(
      runTeardown({
        repository: {
          freezeVmPublicationsForDeletion: (input) => {
            events.push(`freeze:${input.providerVmId}`);
            return Effect.succeed({
              kind: "ready",
              vmId: "00000000-0000-4000-8000-000000000001",
              publications: [
                {
                  publicationId: "00000000-0000-4000-8000-000000000002",
                  provider: "freestyle",
                  hostname: "one.preview.example.test",
                  providerTlsRuleId: "tls-one",
                  state: "disabling",
                },
                {
                  publicationId: "00000000-0000-4000-8000-000000000003",
                  provider: "freestyle",
                  hostname: "two.preview.example.test",
                  providerTlsRuleId: null,
                  state: "disabling",
                },
              ],
            });
          },
          finishDisablePublication: (input) => {
            events.push(`finish:${input.id}`);
            return Effect.succeed({ state: "disabled" } as never);
          },
        },
        provider: {
          deleteTlsRulesForHostname: (hostname) => {
            events.push(`delete:${hostname}`);
            return Effect.succeed(1);
          },
        },
      }),
    );

    expect(result).toEqual({ publications: 2, providerRules: 2 });
    expect(events).toEqual([
      "freeze:provider-vm-1",
      "delete:one.preview.example.test",
      "finish:00000000-0000-4000-8000-000000000002",
      "delete:two.preview.example.test",
      "finish:00000000-0000-4000-8000-000000000003",
    ]);
  });

  test("leaves the durable fence in place when provider deletion is ambiguous", async () => {
    const events: string[] = [];
    const result = await Effect.runPromise(
      Effect.either(
        runTeardown({
          repository: {
            freezeVmPublicationsForDeletion: () => {
              events.push("freeze");
              return Effect.succeed({
                kind: "ready",
                vmId: "00000000-0000-4000-8000-000000000001",
                publications: [
                  {
                    publicationId: "00000000-0000-4000-8000-000000000002",
                    provider: "freestyle",
                    hostname: "one.preview.example.test",
                    providerTlsRuleId: "tls-one",
                    state: "disabling",
                  },
                ],
              });
            },
            finishDisablePublication: () => {
              events.push("finish");
              return Effect.succeed({ state: "disabled" } as never);
            },
          },
          provider: {
            deleteTlsRulesForHostname: () => {
              events.push("provider-delete");
              return Effect.fail(
                new VmPublicationProviderError({
                  operation: "deleteTlsRulesForHostname",
                  cause: new Error("provider unavailable"),
                }),
              );
            },
          },
        }),
      ),
    );

    expect(result._tag).toBe("Left");
    expect(events).toEqual(["freeze", "provider-delete"]);
  });

  test("does not sweep while an earlier publication provider operation holds the lease", async () => {
    const retryAt = new Date("2026-09-02T21:01:00.000Z");
    const result = await Effect.runPromise(
      Effect.either(
        runTeardown({
          repository: {
            freezeVmPublicationsForDeletion: () =>
              Effect.succeed({
                kind: "in_progress",
                vmId: "00000000-0000-4000-8000-000000000001",
                retryAt,
              }),
          },
        }),
      ),
    );

    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left).toMatchObject({
        _tag: "PublicationProvisioningBusyError",
        retryAt,
      });
    }
  });
});
