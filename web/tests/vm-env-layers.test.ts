// Postgres-backed tests for the env-layer cache (`cloud_vm_env_layers`).
// Run with `CMUX_DB_TEST=1 DATABASE_URL=... bun test vm-env-layers` against a
// migrated local database (`bun db:up && bun db:migrate`).

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, VmRepositoryLive } from "../services/vms/repository";
import {
  VmEnvLayerOwnershipError,
  VmEnvProviderUnsupportedError,
} from "../services/vms/errors";
import { listEnvLayers, recordEnvLayer, resolveEnvLayers } from "../services/vms/workflows";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  return url;
}

const unusedProvider: VmProviderGatewayShape = {
  create: () => Effect.die(new Error("provider unused in env-layer tests")),
  destroy: () => Effect.die(new Error("provider unused in env-layer tests")),
  exec: () => Effect.die(new Error("provider unused in env-layer tests")),
  openAttach: () => Effect.die(new Error("provider unused in env-layer tests")),
  openSSH: () => Effect.die(new Error("provider unused in env-layer tests")),
  revokeSSHIdentity: () => Effect.die(new Error("provider unused in env-layer tests")),
};

const layers = Layer.mergeAll(
  VmRepositoryLive,
  Layer.succeed(VmProviderGateway, unusedProvider),
  Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
);

function run<A, E>(program: Effect.Effect<A, E, VmRepository | VmProviderGateway | VmBillingGateway>) {
  return Effect.runPromise(program.pipe(Effect.provide(layers)));
}

async function grantSnapshotOwnership(input: {
  userId: string;
  billingTeamId: string;
  snapshotId: string;
}) {
  await sql!`
    insert into cloud_vm_usage_events (user_id, billing_team_id, event_type, provider, metadata)
    values (${input.userId}, ${input.billingTeamId}, 'vm.snapshot.created', 'freestyle',
            ${sql!.json({ snapshotId: input.snapshotId })})
  `;
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  if (!runDbTests) return;
  await sql!`delete from cloud_vm_env_layers where billing_team_id like 'team-envlayer-%'`;
  await sql!`delete from cloud_vm_usage_events where billing_team_id like 'team-envlayer-%'`;
  await closeCloudDbForTests();
  await sql?.end();
});

describe("env layer cache", () => {
  dbTest("register then resolve returns the deepest cached layer", async () => {
    const scope = { userId: "user-envlayer-1", billingTeamId: "team-envlayer-deepest" };
    const chain = ["hash-envlayer-deep-0", "hash-envlayer-deep-1", "hash-envlayer-deep-2"];
    for (const [index, chainHash] of chain.slice(0, 2).entries()) {
      const snapshotId = `snap-envlayer-deep-${index}`;
      await grantSnapshotOwnership({ ...scope, snapshotId });
      await run(recordEnvLayer({
        ...scope,
        provider: "freestyle",
        baseImageId: "img-envlayer",
        chainHash,
        stepIndex: index,
        stepName: `step ${index}`,
        specDigest: "digest-envlayer-deep",
        snapshotId,
      }));
    }

    const layer = await run(resolveEnvLayers({
      billingTeamId: scope.billingTeamId,
      provider: "freestyle",
      chainHashes: chain,
    }));
    expect(layer?.stepIndex).toBe(1);
    expect(layer?.snapshotId).toBe("snap-envlayer-deep-1");

    // Editing step 1 changes its hash: only layer 0 should match now.
    const editedChain = [chain[0], "hash-envlayer-deep-1-edited", "hash-envlayer-deep-2-edited"];
    const shallow = await run(resolveEnvLayers({
      billingTeamId: scope.billingTeamId,
      provider: "freestyle",
      chainHashes: editedChain,
    }));
    expect(shallow?.stepIndex).toBe(0);
  });

  dbTest("resolve derives depth from the requested chain, not stored stepIndex", async () => {
    const scope = { userId: "user-envlayer-5", billingTeamId: "team-envlayer-depth" };
    // Register the chain's FIRST hash with a bogus deep stepIndex. Resolve
    // must skip it (stored index disagrees with the hash's position in the
    // requested chain) instead of letting it outrank the honest layer below,
    // which would make builds skip real steps.
    const bogusSnapshot = "snap-envlayer-depth-bogus";
    await grantSnapshotOwnership({ ...scope, snapshotId: bogusSnapshot });
    await run(recordEnvLayer({
      ...scope,
      provider: "freestyle",
      baseImageId: "img-envlayer",
      chainHash: "hash-envlayer-depth-0",
      stepIndex: 5,
      stepName: "bogus",
      specDigest: "digest-envlayer-depth",
      snapshotId: bogusSnapshot,
    }));
    const honestSnapshot = "snap-envlayer-depth-1";
    await grantSnapshotOwnership({ ...scope, snapshotId: honestSnapshot });
    await run(recordEnvLayer({
      ...scope,
      provider: "freestyle",
      baseImageId: "img-envlayer",
      chainHash: "hash-envlayer-depth-1",
      stepIndex: 1,
      stepName: "step 1",
      specDigest: "digest-envlayer-depth",
      snapshotId: honestSnapshot,
    }));

    const layer = await run(resolveEnvLayers({
      billingTeamId: scope.billingTeamId,
      provider: "freestyle",
      chainHashes: ["hash-envlayer-depth-0", "hash-envlayer-depth-1", "hash-envlayer-depth-2"],
    }));
    expect(layer?.snapshotId).toBe(honestSnapshot);
    expect(layer?.stepIndex).toBe(1);

    // The poisoned row alone resolves to nothing...
    const poisoned = await run(resolveEnvLayers({
      billingTeamId: scope.billingTeamId,
      provider: "freestyle",
      chainHashes: ["hash-envlayer-depth-0"],
    }));
    expect(poisoned).toBeNull();

    // ...and an honest re-registration repairs it via the upsert path.
    await run(recordEnvLayer({
      ...scope,
      provider: "freestyle",
      baseImageId: "img-envlayer",
      chainHash: "hash-envlayer-depth-0",
      stepIndex: 0,
      stepName: "step 0",
      specDigest: "digest-envlayer-depth",
      snapshotId: bogusSnapshot,
    }));
    const repaired = await run(resolveEnvLayers({
      billingTeamId: scope.billingTeamId,
      provider: "freestyle",
      chainHashes: ["hash-envlayer-depth-0"],
    }));
    expect(repaired?.stepIndex).toBe(0);
  });

  dbTest("layers are isolated per billing team", async () => {
    const owner = { userId: "user-envlayer-2", billingTeamId: "team-envlayer-owner" };
    const snapshotId = "snap-envlayer-isolated";
    await grantSnapshotOwnership({ ...owner, snapshotId });
    await run(recordEnvLayer({
      ...owner,
      provider: "freestyle",
      baseImageId: "img-envlayer",
      chainHash: "hash-envlayer-isolated",
      stepIndex: 0,
      stepName: "step 0",
      specDigest: "digest-envlayer-isolated",
      snapshotId,
    }));

    const otherTeam = await run(resolveEnvLayers({
      billingTeamId: "team-envlayer-other",
      provider: "freestyle",
      chainHashes: ["hash-envlayer-isolated"],
    }));
    expect(otherTeam).toBeNull();

    const sameTeam = await run(resolveEnvLayers({
      billingTeamId: owner.billingTeamId,
      provider: "freestyle",
      chainHashes: ["hash-envlayer-isolated"],
    }));
    expect(sameTeam?.snapshotId).toBe(snapshotId);
  });

  dbTest("re-registering the same chain hash upserts instead of failing", async () => {
    const scope = { userId: "user-envlayer-3", billingTeamId: "team-envlayer-upsert" };
    for (const snapshotId of ["snap-envlayer-upsert-a", "snap-envlayer-upsert-b"]) {
      await grantSnapshotOwnership({ ...scope, snapshotId });
      await run(recordEnvLayer({
        ...scope,
        provider: "freestyle",
        baseImageId: "img-envlayer",
        chainHash: "hash-envlayer-upsert",
        stepIndex: 0,
        stepName: "step 0",
        specDigest: "digest-envlayer-upsert",
        snapshotId,
      }));
    }
    const listed = await run(listEnvLayers({
      billingTeamId: scope.billingTeamId,
      provider: "freestyle",
    }));
    const matching = listed.filter((layer) => layer.chainHash === "hash-envlayer-upsert");
    expect(matching.length).toBe(1);
    expect(matching[0]?.snapshotId).toBe("snap-envlayer-upsert-b");
  });

  dbTest("registering a snapshot the team does not own is rejected", async () => {
    await expect(run(recordEnvLayer({
      userId: "user-envlayer-4",
      billingTeamId: "team-envlayer-notowned",
      provider: "freestyle",
      baseImageId: "img-envlayer",
      chainHash: "hash-envlayer-notowned",
      stepIndex: 0,
      stepName: "step 0",
      specDigest: "digest-envlayer-notowned",
      snapshotId: "snap-envlayer-never-created",
    }))).rejects.toThrow();

    const listed = await run(listEnvLayers({ billingTeamId: "team-envlayer-notowned" }));
    expect(listed.length).toBe(0);
  });

  test("non-freestyle providers are rejected before any database work", async () => {
    const resolveError = await run(
      resolveEnvLayers({
        billingTeamId: "team-envlayer-provider",
        provider: "e2b",
        chainHashes: ["hash-any"],
      }).pipe(Effect.flip),
    );
    expect(resolveError).toBeInstanceOf(VmEnvProviderUnsupportedError);

    const recordError = await run(
      recordEnvLayer({
        userId: "user-envlayer-5",
        billingTeamId: "team-envlayer-provider",
        provider: "daytona",
        baseImageId: "img",
        chainHash: "hash-any",
        stepIndex: 0,
        stepName: null,
        specDigest: "digest",
        snapshotId: "snap",
      }).pipe(Effect.flip),
    );
    expect(recordError).toBeInstanceOf(VmEnvProviderUnsupportedError);
  });

  dbTest("ownership rejection surfaces the typed error", async () => {
    const error = await run(
      recordEnvLayer({
        userId: "user-envlayer-6",
        billingTeamId: "team-envlayer-typed",
        provider: "freestyle",
        baseImageId: "img",
        chainHash: "hash-envlayer-typed",
        stepIndex: 0,
        stepName: null,
        specDigest: "digest",
        snapshotId: "snap-envlayer-typed-missing",
      }).pipe(Effect.flip),
    );
    expect(error).toBeInstanceOf(VmEnvLayerOwnershipError);
  });
});
