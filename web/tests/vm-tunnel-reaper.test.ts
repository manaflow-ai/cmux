import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import type { ProviderTunnel } from "../services/vms/drivers";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  DEFAULT_VM_TUNNEL_STALE_AFTER_DAYS,
  readVmTunnel,
  reapStaleVmTunnels,
  vmTunnelStaleAfterMs,
} from "../services/vms/privateNetwork";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  VmRepository,
  type CloudVmNetworkRow,
  type CloudVmTunnelRow,
  type VmRepositoryShape,
} from "../services/vms/repository";

const DAY_MS = 24 * 60 * 60 * 1000;
const NOW = Date.parse("2026-09-30T00:00:00.000Z");
const CLIENT_KEY = Buffer.alloc(32, 1).toString("base64");

function tunnelRow(id: string, lastActivityDaysAgo: number, overrides: Partial<CloudVmTunnelRow> = {}): CloudVmTunnelRow {
  const at = new Date(NOW - lastActivityDaysAgo * DAY_MS);
  return {
    id,
    userId: "user-1",
    networkId: "00000000-0000-4000-8000-0000000000aa",
    accessGrantId: "00000000-0000-4000-8000-0000000000c1",
    provider: "freestyle",
    providerTunnelId: `tun-${id}`,
    deviceFingerprint: `mac-${id}`,
    tunnelPurpose: "browser",
    deviceName: "Test Mac",
    clientPublicKey: CLIENT_KEY,
    addressV4: "10.40.0.2",
    addressV6: "fd00:40::2",
    createdAt: at,
    updatedAt: at,
    lastConfigIssuedAt: at,
    revokedAt: null,
    ...overrides,
  };
}

type World = {
  rows: Map<string, CloudVmTunnelRow>;
  candidateQueries: Array<{ inactiveBefore: Date; limit: number }>;
  deleted: string[];
  revoked: string[];
  updates: Array<{ id: string; configIssued?: boolean }>;
  leaseClaimed: boolean;
  deleteFails: Set<string>;
};

function world(rows: CloudVmTunnelRow[]): World {
  return {
    rows: new Map(rows.map((row) => [row.id, row])),
    candidateQueries: [],
    deleted: [],
    revoked: [],
    updates: [],
    leaseClaimed: true,
    deleteFails: new Set(),
  };
}

function repo(state: World, candidates: CloudVmTunnelRow[]): VmRepositoryShape {
  const live = () => [...state.rows.values()].filter((row) => row.revokedAt === null);
  const shape: Partial<VmRepositoryShape> = {
    listStaleTunnelCandidates: (input) => Effect.sync(() => {
      state.candidateQueries.push(input);
      return candidates.slice(0, input.limit);
    }),
    findNetwork: () => Effect.succeed({
      id: "00000000-0000-4000-8000-0000000000aa",
      userId: "user-1",
      provider: "freestyle",
      providerNetworkId: "vpc-1",
      slug: "cmux-net-1",
      cidr: "10.40.0.0/24",
      cidrV6: "fd00:40::/64",
      createdAt: new Date(NOW),
      updatedAt: new Date(NOW),
    } satisfies CloudVmNetworkRow),
    upsertNetwork: () => Effect.die("unused"),
    findTunnel: (input) => Effect.sync(() => live().find((row) =>
      row.userId === input.userId && row.deviceFingerprint === input.deviceFingerprint &&
      row.tunnelPurpose === input.tunnelPurpose) ?? null),
    listUserTunnels: () => Effect.sync(live),
    insertTunnel: () => Effect.die("unused"),
    updateTunnel: (input) => Effect.sync(() => {
      state.updates.push({ id: input.id, configIssued: input.configIssued });
      return state.rows.get(input.id)!;
    }),
    revokeTunnel: (id) => Effect.sync(() => {
      state.revoked.push(id);
      const row = state.rows.get(id);
      if (row) state.rows.set(id, { ...row, revokedAt: new Date(NOW) });
      return true;
    }),
    findAccessGrant: () => Effect.die("unused"),
    findBlockingRevokedAccessGrant: () => Effect.succeed(null),
    listUserAccessGrants: () => Effect.succeed([]),
    upsertAccessGrant: () => Effect.die("unused"),
    upsertAccessGrantSession: () => Effect.void,
    listAccessGrantSessionIds: () => Effect.succeed([]),
    renameAccessGrant: () => Effect.die("unused"),
    listAccessGrantTunnels: () => Effect.succeed([]),
    claimAccessGrantMutation: () => Effect.sync(() => state.leaseClaimed),
    releaseAccessGrantMutation: () => Effect.void,
    revokeAccessGrant: () => Effect.succeed(true),
  };
  return shape as VmRepositoryShape;
}

function providerTunnel(id: string): ProviderTunnel {
  return {
    id,
    clientConfig: "[Interface]\nPrivateKey =\n[Peer]\n",
    clientPublicKey: CLIENT_KEY,
    serverPublicKey: "server-key",
    endpointHost: "vpn.freestyle.sh",
    endpointPort: 51820,
    routes: ["10.40.0.0/24"],
    addressV4: "10.40.0.2",
    addressV6: "fd00:40::2",
  };
}

function gateway(state: World): VmProviderGatewayShape {
  return {
    create: () => Effect.die("unused"),
    destroy: () => Effect.void,
    exec: () => Effect.die("unused"),
    openAttach: () => Effect.die("unused"),
    openSSH: () => Effect.die("unused"),
    revokeSSHIdentity: () => Effect.void,
    supportsPrivateNetworking: () => true,
    ensureNetwork: () => Effect.die("unused"),
    getNetwork: () => Effect.succeed(null),
    createTunnel: () => Effect.die("unused"),
    getTunnel: (_provider, tunnelId) => Effect.succeed(providerTunnel(tunnelId)),
    rotateTunnelKey: () => Effect.die("unused"),
    deleteTunnel: (provider, tunnelId) => {
      if (state.deleteFails.has(tunnelId)) {
        return Effect.fail(new VmProviderOperationError({ provider, operation: "deleteTunnel", cause: new Error("down") }));
      }
      return Effect.sync(() => { state.deleted.push(tunnelId); });
    },
  };
}

function run<A, E>(state: World, candidates: CloudVmTunnelRow[], program: Effect.Effect<A, E, VmRepository | VmProviderGateway>) {
  return Effect.runPromise(program.pipe(Effect.provide(Layer.mergeAll(
    Layer.succeed(VmRepository, repo(state, candidates)),
    Layer.succeed(VmProviderGateway, gateway(state)),
  ))));
}

// Every dogfood build and reinstall enrolls a new per-installation tunnel, and
// each holds an address in the owner's /24 forever. The cron frees addresses
// held by tunnels that a newer tunnel on the same Mac replaced long ago.
describe("stale tunnel reaping", () => {
  test("deletes a stale tunnel at the provider and revokes its row", async () => {
    const stale = tunnelRow("old", 40);
    const state = world([stale, tunnelRow("new", 1)]);
    const result = await run(state, [stale], reapStaleVmTunnels({ now: () => NOW }));

    expect(state.candidateQueries).toEqual([{
      inactiveBefore: new Date(NOW - DEFAULT_VM_TUNNEL_STALE_AFTER_DAYS * DAY_MS),
      limit: 25,
    }]);
    expect(state.deleted).toEqual(["tun-old"]);
    expect(state.revoked).toEqual(["old"]);
    expect(result).toEqual({ candidates: 1, reaped: 1, skipped: 0, failed: 0, budgetExhausted: false });
  });

  test("keeps a tunnel that was re-enrolled after the candidate query", async () => {
    const stale = tunnelRow("old", 40);
    const state = world([tunnelRow("old", 0), tunnelRow("new", 1)]);
    const result = await run(state, [stale], reapStaleVmTunnels({ now: () => NOW }));

    expect(state.deleted).toEqual([]);
    expect(state.revoked).toEqual([]);
    expect(result).toMatchObject({ reaped: 0, skipped: 1 });
  });

  test("skips a Mac whose tunnel mutation is in progress", async () => {
    const stale = tunnelRow("old", 40);
    const state = world([stale]);
    state.leaseClaimed = false;
    const result = await run(state, [stale], reapStaleVmTunnels({ now: () => NOW }));

    expect(state.deleted).toEqual([]);
    expect(result).toMatchObject({ reaped: 0, skipped: 1, failed: 0 });
  });

  test("a provider failure keeps the row and does not stop the batch", async () => {
    const first = tunnelRow("a", 40, { deviceFingerprint: "mac-a" });
    const second = tunnelRow("b", 50, { deviceFingerprint: "mac-b" });
    const state = world([first, second]);
    state.deleteFails.add("tun-a");
    const result = await run(state, [first, second], reapStaleVmTunnels({ now: () => NOW }));

    expect(state.revoked).toEqual(["b"]);
    expect(result).toMatchObject({ candidates: 2, reaped: 1, failed: 1 });
  });

  test("stops when the time budget is spent", async () => {
    const rows = [tunnelRow("a", 40), tunnelRow("b", 41), tunnelRow("c", 42)]
      .map((row, index) => ({ ...row, deviceFingerprint: `mac-${index}` }));
    const state = world(rows);
    let clock = NOW;
    const now = () => {
      const value = clock;
      clock += 6_000;
      return value;
    };
    const result = await run(state, rows, reapStaleVmTunnels({ now, budgetMs: 10_000 }));

    expect(result.budgetExhausted).toBe(true);
    expect(result.reaped).toBeLessThan(3);
  });

  test("the stale window defaults to 30 days and honors a valid override", () => {
    expect(DEFAULT_VM_TUNNEL_STALE_AFTER_DAYS).toBe(30);
    expect(vmTunnelStaleAfterMs({})).toBe(30 * DAY_MS);
    expect(vmTunnelStaleAfterMs({ CMUX_VM_TUNNEL_STALE_AFTER_DAYS: "45" })).toBe(45 * DAY_MS);
    expect(vmTunnelStaleAfterMs({ CMUX_VM_TUNNEL_STALE_AFTER_DAYS: "0" })).toBe(30 * DAY_MS);
    expect(vmTunnelStaleAfterMs({ CMUX_VM_TUNNEL_STALE_AFTER_DAYS: "soon" })).toBe(30 * DAY_MS);
  });
});

describe("tunnel activity", () => {
  test("reading a tunnel's config records it as issued", async () => {
    const row = tunnelRow("old", 40);
    const state = world([row]);
    await run(state, [], readVmTunnel({
      userId: "user-1",
      provider: "freestyle",
      deviceFingerprint: row.deviceFingerprint,
      tunnelPurpose: "browser",
    }));

    expect(state.updates).toEqual([{ id: "old", configIssued: true }]);
  });
});
