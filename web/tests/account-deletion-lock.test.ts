import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { deletePrivateNetworkingForAccountDeletion } from "../services/vms/privateNetwork";
import { VmProviderGateway } from "../services/vms/providerGateway";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";

import { describe, expect, test } from "bun:test";

import type { cloudDb } from "../db/client";
import {
  ACCOUNT_ANALYTICS_FORWARD_LEASE_MS,
  isBlockingAccountDeletionTombstone,
  withAccountDeletionAnalyticsForwardLease,
  withAccountDeletionUserMutation,
} from "../services/account/deletionLock";

describe("account deletion tombstone lock", () => {
  test("blocks fresh nonterminal deletion tombstones", () => {
    const now = new Date("2026-07-09T10:00:00.000Z");

    expect(isBlockingAccountDeletionTombstone({
      status: "pending",
      updatedAt: new Date("2026-07-09T09:55:00.000Z"),
    }, now)).toBe(true);
  });

  test("does not block stale pending deletion tombstones", () => {
    const now = new Date("2026-07-09T10:00:00.000Z");

    expect(isBlockingAccountDeletionTombstone({
      status: "pending",
      updatedAt: new Date("2026-07-09T09:44:59.999Z"),
    }, now)).toBe(false);
  });

  test("keeps terminal deletion tombstones blocking after the lease", () => {
    const now = new Date("2026-07-09T10:00:00.000Z");

    expect(isBlockingAccountDeletionTombstone({
      status: "completed",
      updatedAt: new Date("2026-07-09T09:00:00.000Z"),
    }, now)).toBe(true);
    expect(isBlockingAccountDeletionTombstone({
      status: "cleanup_incomplete",
      updatedAt: new Date("2026-07-09T09:00:00.000Z"),
    }, now)).toBe(true);
  });

  test("starts an analytics forward lease after advisory locks are acquired", async () => {
    let now = new Date("2026-07-09T10:00:00.000Z");
    let insertedExpiresAt: Date | undefined;
    const tx = {
      execute: async () => {
        now = new Date("2026-07-09T10:00:45.000Z");
      },
      select: () => ({
        from: () => ({ where: async () => [] }),
      }),
      delete: () => ({ where: async () => undefined }),
      insert: () => ({
        values: async (values: readonly { readonly expiresAt: Date }[]) => {
          insertedExpiresAt = values[0]?.expiresAt;
        },
      }),
    };
    const db = {
      transaction: async (operation: (transaction: typeof tx) => Promise<unknown>) =>
        await operation(tx),
    } as unknown as ReturnType<typeof cloudDb>;

    await withAccountDeletionAnalyticsForwardLease(
      db,
      ["user-after-lock"],
      async () => "forwarded",
      () => true,
      () => now,
    );

    expect(insertedExpiresAt?.getTime()).toBe(
      now.getTime() + ACCOUNT_ANALYTICS_FORWARD_LEASE_MS,
    );
  });

  test("commits a durable user-mutation lease before external work starts", async () => {
    let transactionDepth = 0;
    let insertedLeaseCount = 0;
    const tx = {
      execute: async () => undefined,
      select: () => ({
        from: () => ({
          where: () => ({
            limit: async () => [],
          }),
        }),
      }),
      delete: () => ({ where: async () => undefined }),
      insert: () => ({
        values: async () => {
          insertedLeaseCount += 1;
        },
      }),
      update: () => ({
        set: () => ({ where: async () => undefined }),
      }),
    };
    const db = {
      transaction: async (
        operation: (transaction: typeof tx) => Promise<unknown>,
      ) => {
        transactionDepth += 1;
        try {
          return await operation(tx);
        } finally {
          transactionDepth -= 1;
        }
      },
    } as unknown as ReturnType<typeof cloudDb>;

    await withAccountDeletionUserMutation(
      db,
      "user-outside-transaction",
      async () => {
        expect(transactionDepth).toBe(0);
        expect(insertedLeaseCount).toBe(1);
        return "completed";
      },
    );
  });
});

test("account deletion removes tunnel team attachments but keeps team networks", async () => {
  const deletedAttachments: string[] = [];
  const deletedNetworks: string[] = [];
  const tunnel = {
    id: "00000000-0000-4000-8000-000000000010",
    userId: "user-1",
    networkId: "00000000-0000-4000-8000-000000000011",
    accessGrantId: "00000000-0000-4000-8000-000000000012",
    provider: "freestyle" as const,
    providerTunnelId: "tun-1",
    deviceFingerprint: "device-1",
    tunnelPurpose: "browser" as const,
    deviceName: null,
    clientPublicKey: "client",
    addressV4: null,
    addressV6: null,
    createdAt: new Date(),
    updatedAt: new Date(),
    lastConfigIssuedAt: null,
    revokedAt: null,
  };
  const teamNetwork = {
    id: "00000000-0000-4000-8000-000000000013",
    teamId: "team-1",
    provider: "freestyle" as const,
    providerNetworkId: "vpc-team",
    slug: "team",
    cidr: "10.5.0.0/24",
    cidrV6: "fd05::/64",
    createdByUserId: "user-1",
    createdAt: new Date(),
    updatedAt: new Date(),
  };
  const repo = {
    findNetwork: () => Effect.succeed(null),
    upsertNetwork: () => Effect.succeed(null as never),
    deleteNetwork: (id: string) => Effect.sync(() => { deletedNetworks.push(id); }),
    listUserTunnels: () => Effect.succeed([tunnel]),
    findTunnel: () => Effect.succeed(tunnel),
    insertTunnel: () => Effect.succeed(tunnel),
    updateTunnel: () => Effect.succeed(tunnel),
    revokeTunnel: () => Effect.succeed(true),
    findTeamNetwork: () => Effect.succeed(teamNetwork),
    upsertTeamNetwork: () => Effect.succeed(teamNetwork),
    listTeamNetworks: () => Effect.succeed([teamNetwork]),
    listTunnelTeamNetworks: () => Effect.succeed([{ tunnelId: tunnel.id, teamNetworkId: teamNetwork.id, addressV4: null, addressV6: null, attachedAt: new Date(), teamNetwork }]),
    insertTunnelTeamNetwork: () => Effect.succeed({} as never),
    deleteTunnelTeamNetwork: (_tunnelId: string, teamNetworkId: string) => Effect.sync(() => { deletedAttachments.push(teamNetworkId); }),
  } as unknown as VmRepositoryShape;
  const gateway = {
    supportsPrivateNetworking: () => true,
    ensureNetwork: () => Effect.succeed({ id: "vpc-user", slug: "user", cidr: null, cidrV6: "fd00::/64" }),
    deleteTunnel: () => Effect.void,
    deleteNetwork: () => Effect.void,
  } as never;
  await Effect.runPromise(deletePrivateNetworkingForAccountDeletion("user-1").pipe(Effect.provide(Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, gateway)) )));
  expect(deletedAttachments).toEqual([teamNetwork.id]);
  expect(deletedNetworks).toEqual([]);
});
