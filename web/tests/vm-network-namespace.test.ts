import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type { ProviderNetwork } from "../services/vms/drivers";
import {
  networkSlugForTeam,
  networkSlugForUser,
  resolveOwnerNetwork,
  tunnelSlugForDevice,
  userNetworkCidr,
  vmNetworkNamespace,
} from "../services/vms/privateNetwork";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";

// Every deployment that shares the Freestyle account (production, staging,
// every dev-backend stack) used to derive the same slugs from a user id, so a
// dev stack enrolled its tunnels into the user's production network.

const PRODUCTION = {};
const DEV = { CMUX_VM_NETWORK_NAMESPACE: "dev-3f9a1c20" };
const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

function ipv4ToInt(address: string): number {
  return address.split(".").reduce((value, octet) => value * 256 + Number(octet), 0);
}

describe("network namespace", () => {
  test("unset or empty keeps the production slugs byte for byte", () => {
    for (const env of [PRODUCTION, { CMUX_VM_NETWORK_NAMESPACE: "" }, { CMUX_VM_NETWORK_NAMESPACE: "  " }]) {
      expect(vmNetworkNamespace(env)).toBeNull();
      expect(networkSlugForUser("user-1", env)).toBe("cmux-net-fa32ad2752b2459c9967835e3631f278");
      expect(networkSlugForTeam("team-1", env)).toBe("cmux-team-net-db541021e5eec8c5590dff3a5962eb9b");
      expect(tunnelSlugForDevice("user-1", "device-1", "terminal", env)).toBe("cmux-wg-07939e1e9fee76ccc1cc2965a0c06c0f");
    }
  });

  test("a namespace separates every slug from production and stays a valid provider slug", () => {
    const slugs = [
      networkSlugForUser("user-1", DEV),
      networkSlugForTeam("team-1", DEV),
      tunnelSlugForDevice("user-1", "device-1", "terminal", DEV),
    ];
    expect(slugs[0]).toStartWith("cmux-dev-3f9a1c20-net-");
    expect(slugs[1]).toStartWith("cmux-dev-3f9a1c20-team-net-");
    expect(slugs[2]).toStartWith("cmux-dev-3f9a1c20-wg-");
    expect(slugs).not.toContain(networkSlugForUser("user-1", PRODUCTION));
    expect(slugs).not.toContain(networkSlugForTeam("team-1", PRODUCTION));
    expect(slugs).not.toContain(tunnelSlugForDevice("user-1", "device-1", "terminal", PRODUCTION));
    for (const slug of slugs) {
      expect(slug.length).toBeLessThanOrEqual(63);
      expect(slug).toMatch(SLUG);
    }
    expect(networkSlugForUser("user-1", { CMUX_VM_NETWORK_NAMESPACE: "dev-other" })).not.toBe(slugs[0]);
  });

  test("a malformed namespace fails closed instead of falling back to production", () => {
    for (const value of ["Dev", "dev_1", "-dev", "dev-", "dev--1", "a".repeat(17), "dev 1"]) {
      expect(() => vmNetworkNamespace({ CMUX_VM_NETWORK_NAMESPACE: value })).toThrow();
      expect(() => networkSlugForUser("user-1", { CMUX_VM_NETWORK_NAMESPACE: value })).toThrow();
    }
  });
});

describe("user network CIDR", () => {
  // Freestyle derives a /24 (254 members) when no CIDR is named, and a VPC's
  // CIDR cannot change after create. Every Mac tunnel holds one address, so a
  // /24 filled up; production names a /16 instead.
  test("is a stable, aligned /16 inside 10.192.0.0/10", () => {
    const cidrs = ["user-1", "user-2", "a-much-longer-stack-user-id"].map((userId) => userNetworkCidr(userId));
    expect(userNetworkCidr("user-1")).toBe(cidrs[0]);
    const low = ipv4ToInt("10.192.0.0");
    const high = ipv4ToInt("10.255.255.255");
    for (const cidr of cidrs) {
      const [address, prefix] = cidr.split("/");
      expect(prefix).toBe("16");
      const base = ipv4ToInt(address!);
      expect(base % 65536).toBe(0);
      expect(base).toBeGreaterThanOrEqual(low);
      expect(base + 65535).toBeLessThanOrEqual(high);
    }
  });
});

const NEW_NETWORK: ProviderNetwork = { id: "vpc-new", slug: "ignored", cidr: null, cidrV6: "fd00:1::/64" };

async function provisionWith(env: Record<string, string | undefined>) {
  const requests: Array<{ slug: string; cidr?: string }> = [];
  const gateway = {
    supportsPrivateNetworking: () => true,
    ensureNetwork: (_provider: string, options: { slug: string; cidr?: string }) => Effect.sync(() => {
      requests.push(options);
      return { ...NEW_NETWORK, slug: options.slug, cidr: options.cidr ?? "10.16.1.0/24" };
    }),
  } as unknown as VmProviderGatewayShape;
  const repo = {
    findNetwork: () => Effect.succeed(null),
    upsertNetwork: (input: { providerNetworkId: string; slug: string; cidr: string | null }) => Effect.succeed({
      id: "00000000-0000-4000-8000-0000000000aa",
      userId: "user-1",
      provider: "freestyle",
      cidrV6: null,
      createdAt: new Date(),
      updatedAt: new Date(),
      ...input,
    }),
  } as unknown as VmRepositoryShape;
  const previous = process.env.CMUX_VM_NETWORK_NAMESPACE;
  if (env.CMUX_VM_NETWORK_NAMESPACE === undefined) delete process.env.CMUX_VM_NETWORK_NAMESPACE;
  else process.env.CMUX_VM_NETWORK_NAMESPACE = env.CMUX_VM_NETWORK_NAMESPACE;
  try {
    const network = await Effect.runPromise(resolveOwnerNetwork({ userId: "user-1", provider: "freestyle" }).pipe(
      Effect.provide(Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, gateway))),
    ));
    return { requests, network };
  } finally {
    if (previous === undefined) delete process.env.CMUX_VM_NETWORK_NAMESPACE;
    else process.env.CMUX_VM_NETWORK_NAMESPACE = previous;
  }
}

describe("first network provisioning", () => {
  test("production asks for the user's /16 under the production slug", async () => {
    const { requests, network } = await provisionWith(PRODUCTION);
    expect(requests).toEqual([expect.objectContaining({
      slug: networkSlugForUser("user-1", PRODUCTION),
      cidr: userNetworkCidr("user-1"),
    })]);
    expect(network.cidr).toBe(userNetworkCidr("user-1"));
  });

  test("a namespaced deployment gets its own slug and the platform's account-unique /24", async () => {
    const { requests } = await provisionWith(DEV);
    expect(requests).toHaveLength(1);
    expect(requests[0]!.slug).toBe(networkSlugForUser("user-1", DEV));
    expect(requests[0]!.cidr).toBeUndefined();
  });
});
