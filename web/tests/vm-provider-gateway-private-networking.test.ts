import { expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import type { Freestyle } from "freestyle";

const calls = {
  attach: [] as Array<{ tunnelId: string; networkId: string }>,
  detach: [] as Array<{ tunnelId: string; networkId: string }>,
  get: [] as string[],
  listTunnels: [] as string[],
};

const client = {
  vpc: {
    get: async (idOrSlug: string) => {
      calls.get.push(idOrSlug);
      return { id: "vpc-team", slug: idOrSlug, cidr: "10.82.45.0/24", cidrV6: "fd82::/64" };
    },
    ref: (networkId: string) => ({
      tunnels: {
        list: async () => {
          calls.listTunnels.push(networkId);
          return { tunnels: [{ id: "tun-team" }], totalCount: 1 };
        },
      },
    }),
  },
  tunnels: {
    attachVpc: async (tunnelId: string, networkId: string) => {
      calls.attach.push({ tunnelId, networkId });
      return { attachments: [{ vpcId: networkId, ipv4: "10.82.45.2", ipv6: "fd82::2" }] };
    },
    detachVpc: async (tunnelId: string, networkId: string) => {
      calls.detach.push({ tunnelId, networkId });
    },
  },
} as unknown as Freestyle;

const provider = new FreestyleProvider({ client: () => client });
const realDrivers = await import("../services/vms/drivers");
mock.module("../services/vms/drivers", () => ({ ...realDrivers, getProvider: () => provider }));
const { VmProviderGateway, VmProviderGatewayLive } = await import("../services/vms/providerGateway");

test("the live gateway preserves private-network driver method receivers", async () => {
  const attachment = await Effect.runPromise(Effect.gen(function* () {
    const gateway = yield* VmProviderGateway;
    const network = yield* gateway.getNetwork!("freestyle", "cmux-team-net-test");
    const tunnelIds = yield* gateway.listNetworkTunnelIds!("freestyle", "vpc-team");
    const result = yield* gateway.attachTunnelNetwork!("freestyle", "tun-team", "vpc-team");
    yield* gateway.detachTunnelNetwork!("freestyle", "tun-team", "vpc-team");
    return { network, tunnelIds, result };
  }).pipe(Effect.provide(VmProviderGatewayLive)));

  expect(attachment.network).toEqual({ id: "vpc-team", slug: "cmux-team-net-test", cidr: "10.82.45.0/24", cidrV6: "fd82::/64" });
  expect(attachment.tunnelIds).toEqual(["tun-team"]);
  expect(attachment.result).toEqual({ networkId: "vpc-team", addressV4: "10.82.45.2", addressV6: "fd82::2" });
  expect(calls.get).toEqual(["cmux-team-net-test"]);
  expect(calls.listTunnels).toEqual(["vpc-team"]);
  expect(calls.attach).toEqual([{ tunnelId: "tun-team", networkId: "vpc-team" }]);
  expect(calls.detach).toEqual([{ tunnelId: "tun-team", networkId: "vpc-team" }]);
});
