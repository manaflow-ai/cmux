/**
 * A TenantOwnsResource proof's upstream id lives only with the minted proof
 * object. A copied proof, even with a forged upstream id beside it, reaches
 * nothing upstream.
 */
import { name } from "@gdp-ts/core";
import { Effect, Exit, Layer, Option, Redacted } from "effect";
import { describe, expect, it } from "vitest";
import { OwnershipStore } from "../../src/db/stores.ts";
import type { Principal } from "../../src/domain/principal.ts";
import { newApiKeyId, newVmId, TenantId, UpstreamId } from "../../src/lib/ids.ts";
import { keyHasScope } from "../../src/proofs/key-has-scope.ts";
import { tenantOwnsVm } from "../../src/proofs/tenant-owns-resource.ts";
import { makeUpstreamClient } from "../../src/upstream/live.ts";

describe("TenantOwnsResource evidence", () => {
  it("cannot be copied or re-pointed", async () => {
    const vmId = newVmId();
    const tenantId = TenantId.make("team_alpha");
    const requested: string[] = [];
    const client = makeUpstreamClient({
      baseUrl: "https://upstream.test",
      apiKey: Redacted.make("k"),
      environment: "local",
      fetch: async (request) => {
        requested.push(new URL(request.url).pathname);
        return Response.json({ state: "running", resources: { cpu: 1, memory: 1, storage: 1 }, createdAt: "t", updatedAt: "t" });
      },
    });
    const store = Layer.succeed(OwnershipStore, {
      find: (tenant, kind, cmuxId) =>
        Effect.succeed(
          Option.some({
            tenantId: tenant,
            kind,
            cmuxId,
            upstreamId: UpstreamId.make("vm-own"),
            createdBy: "user:x",
            createdAt: new Date(),
            displayName: null,
            labels: {},
          }),
        ),
      record: () => Effect.void,
      listPage: () => Effect.succeed([]),
      countLive: () => Effect.succeed(0),
      markDeleted: () => Effect.void,
    });
    const principal: Principal = {
      tenantId,
      actor: { kind: "api_key", keyId: newApiKeyId() },
      scopes: new Set(["vm:read"]),
      resourceAllowlist: null,
      credentialExpiresAt: null,
    };

    const run = (forge: boolean) =>
      Effect.runPromiseExit(
        name(principal, vmId, (caller, vm) =>
          Effect.gen(function* () {
            const scope = keyHasScope(caller, "vm:read");
            const owns = yield* tenantOwnsVm(caller, vm);
            if (scope === null || owns === null) return yield* Effect.dieMessage("setup");
            const presented = forge ? { ...owns, upstreamId: UpstreamId.make("vm-victim") } : owns;
            return yield* client.getVm(vm, { owns: presented, scope });
          }),
        ).pipe(Effect.provide(store)),
      );

    expect(Exit.isSuccess(await run(false))).toBe(true);
    expect(Exit.isFailure(await run(true))).toBe(true);
    expect(requested).toEqual(["/v5/vms/vm-own"]);
  });
});
