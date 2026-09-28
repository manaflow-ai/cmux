import { expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import type { Freestyle } from "freestyle";

const calls = {
  attach: [] as Array<{ tunnelId: string; networkId: string }>,
  detach: [] as Array<{ tunnelId: string; networkId: string }>,
};

const client = {
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
    const result = yield* gateway.attachTunnelNetwork!("freestyle", "tun-team", "vpc-team");
    yield* gateway.detachTunnelNetwork!("freestyle", "tun-team", "vpc-team");
    return result;
  }).pipe(Effect.provide(VmProviderGatewayLive)));

  expect(attachment).toEqual({ networkId: "vpc-team", addressV4: "10.82.45.2", addressV6: "fd82::2" });
  expect(calls.attach).toEqual([{ tunnelId: "tun-team", networkId: "vpc-team" }]);
  expect(calls.detach).toEqual([{ tunnelId: "tun-team", networkId: "vpc-team" }]);
});
