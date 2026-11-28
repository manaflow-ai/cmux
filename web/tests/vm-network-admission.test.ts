import { beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";

import { ProviderNetworkFullError } from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  admitNetworkAddress,
  ipv4CidrCapacity,
  networkAdmissionVerdict,
  resetNetworkAddressAlertsForTest,
} from "../services/vms/networkAdmission";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

const TEAM_NET = { providerNetworkId: "vpc-team", cidr: "10.40.0.0/24", scope: "team" as const };

function input(network = TEAM_NET) {
  return { provider: "freestyle" as const, userId: "user-1", billingTeamId: "team-1", network, vmId: "vm-new" };
}

function repoHolding(count: number | "error") {
  const calls: unknown[] = [];
  return {
    calls,
    repo: {
      countNetworkAddressHolders: (args: unknown) => {
        calls.push(args);
        return count === "error" ? Effect.fail(new Error("db down") as never) : Effect.succeed(count);
      },
    },
  };
}

beforeEach(() => resetNetworkAddressAlertsForTest());

describe("ipv4CidrCapacity", () => {
  test("counts members the way the provider does", () => {
    expect(ipv4CidrCapacity("10.40.0.0/24")).toBe(254);
    expect(ipv4CidrCapacity("10.192.16.0/20")).toBe(4094);
    expect(ipv4CidrCapacity(null)).toBeNull();
    expect(ipv4CidrCapacity("fd00::/64")).toBeNull();
    expect(ipv4CidrCapacity("10.0.0.0/31")).toBeNull();
  });
});

describe("networkAdmissionVerdict", () => {
  // held includes the new machine's own in-flight row.
  test("admits below 80%, alerts from 80%, refuses past capacity", () => {
    expect(networkAdmissionVerdict({ held: 203, capacity: 254, machines: 203, tunnels: null })).toBe("admit");
    expect(networkAdmissionVerdict({ held: 204, capacity: 254, machines: 204, tunnels: null })).toBe("alert");
    expect(networkAdmissionVerdict({ held: 254, capacity: 254, machines: 254, tunnels: null })).toBe("alert");
    expect(networkAdmissionVerdict({ held: 255, capacity: 254, machines: 250, tunnels: 5 })).toBe("full");
  });
});

describe("admitNetworkAddress", () => {
  test("a tunnel-heavy network with few machines is full: tunnels are always counted", async () => {
    const { repo, calls } = repoHolding(10);
    let tunnelReads = 0;
    const result = await Effect.runPromise(Effect.either(admitNetworkAddress(repo, {
      listNetworkTunnelIds: () => Effect.sync(() => { tunnelReads += 1; return Array.from({ length: 245 }, (_, i) => `wg-${i}`); }),
    }, input())));
    expect(tunnelReads).toBe(1);
    expect(result._tag).toBe("Left");
    expect(calls).toEqual([{ provider: "freestyle", userId: "user-1", billingTeamId: "team-1", scope: "team", cidr: "10.40.0.0/24" }]);
  });

  test("machines plus Mac tunnels past the CIDR refuse before the provider start, as vm_network_full", async () => {
    const { repo } = repoHolding(250);
    const error = await Effect.runPromise(Effect.flip(admitNetworkAddress(repo, {
      listNetworkTunnelIds: () => Effect.succeed(["t1", "t2", "t3", "t4", "t5"]),
    }, input())));
    expect(error).toBeInstanceOf(VmProviderOperationError);
    expect((error as VmProviderOperationError).cause).toBeInstanceOf(ProviderNetworkFullError);
    const response = await vmWorkflowErrorResponse(error as VmProviderOperationError);
    expect(response).not.toBeNull();
    expect(response!.status).toBe(409);
    expect(await response!.json()).toMatchObject({ error: "vm_network_full" });
  });

  test("paused machines are part of the count the repository returns, so a network of paused machines is full", async () => {
    // The repository counts provisioning, running and paused rows; a paused
    // provider VM keeps its address. 255 = 254 held + this create's row.
    const { repo } = repoHolding(255);
    const exit = await Effect.runPromiseExit(admitNetworkAddress(repo, {}, input()));
    expect(exit._tag).toBe("Failure");
  });

  test("an unknown count admits: admission is never the outage", async () => {
    expect(await Effect.runPromise(admitNetworkAddress(repoHolding("error").repo, {}, input()))).toBeNull();
    expect(await Effect.runPromise(admitNetworkAddress({}, {}, input()))).toBeNull();
    expect(await Effect.runPromise(admitNetworkAddress(repoHolding(999).repo, {}, input({ ...TEAM_NET, cidr: null as never })))).toBeNull();
  });

  test("a tunnel read that fails or hangs counts no tunnels", async () => {
    const { repo } = repoHolding(200);
    const usage = await Effect.runPromise(admitNetworkAddress(repo, {
      listNetworkTunnelIds: () => Effect.fail(new Error("provider down")),
    }, input()));
    expect(usage).toMatchObject({ held: 200, tunnels: null });
  });
});
