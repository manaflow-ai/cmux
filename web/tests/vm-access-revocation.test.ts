import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  VmProviderGateway,
  type VmProviderGatewayShape,
} from "../services/vms/providerGateway";
import {
  VmRepository,
  type CloudVmAccessLeaseRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import { revokeUserVmAccess } from "../services/vms/workflows";

describe("Cloud VM access revocation", () => {
  test("revokes the signed-out user's active endpoint leases", async () => {
    const revokedProviderVMs: string[] = [];
    const markedLeaseIDs: string[] = [];
    const leases = [
      {
        id: "lease-a",
        vmId: "vm-a",
        userId: "user-a",
        kind: "pty",
        tokenHash: "hash-a",
        providerIdentityHandle: null,
        sessionId: "session-a",
        transport: "websocket",
        metadata: {},
        expiresAt: new Date(Date.now() + 60_000),
        consumedAt: null,
        revokedAt: null,
        createdAt: new Date(),
        provider: "freestyle",
        providerVmId: "machine-a",
      },
      {
        id: "lease-b",
        vmId: "vm-a",
        userId: "user-a",
        kind: "rpc",
        tokenHash: "hash-b",
        providerIdentityHandle: null,
        sessionId: "session-a",
        transport: "websocket",
        metadata: {},
        expiresAt: new Date(Date.now() + 60_000),
        consumedAt: null,
        revokedAt: null,
        createdAt: new Date(),
        provider: "freestyle",
        providerVmId: "machine-a",
      },
    ] as unknown as CloudVmAccessLeaseRow[];

    const repo = {
      activeAccessLeasesForUser: () => Effect.succeed(leases),
      markLeasesRevoked: (ids: readonly string[]) => {
        markedLeaseIDs.push(...ids);
        return Effect.void;
      },
    } as unknown as VmRepositoryShape;
    const provider = {
      revokeEndpointLeases: (_provider: string, providerVmId: string) => {
        revokedProviderVMs.push(providerVmId);
        return Effect.void;
      },
    } as unknown as VmProviderGatewayShape;
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, provider),
    );

    const result = await Effect.runPromise(
      revokeUserVmAccess({ userId: "user-a" }).pipe(Effect.provide(layer)),
    );

    expect(result.revoked).toBe(2);
    expect(result.cleanupFailures).toBe(0);
    expect(revokedProviderVMs).toEqual(["machine-a"]);
    expect(markedLeaseIDs.sort()).toEqual(["lease-a", "lease-b"]);
  });
});
