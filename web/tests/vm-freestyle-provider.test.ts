import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, setSystemTime, test } from "bun:test";
import { FreestyleApiError, type Freestyle } from "freestyle";
import {
  FREESTYLE_NETWORK_FIREWALL_RULES,
  FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
  FreestyleProvider,
  PORT_OPEN_LEASE_TTL_SECONDS,
  freestyleCmuxRemoteRoute,
  freestyleNetworkAddressMetadata,
  freestyleRouteAddressesFromMetadata,
  freestyleDesktopHealCommand,
  freestyleEdgeRules,
  freestyleFirewallRules,
  freestylePortAddress,
  freestylePortUrls,
  mapFreestyleState,
  normalizeFreestyleExecTimeout,
} from "../services/vms/drivers/freestyle";
import type { VMProvider } from "../services/vms/drivers/types";
import { ProviderError, ProviderTunnelNetworkOverlapError, type VmEdgeRule } from "../services/vms/drivers/types";
import { isProviderTunnelNetworkOverlap } from "../services/vms/providerErrors";
import { DEVBOX_DESKTOP_NOVNC_PORT } from "../services/vms/images/desktop";

const VM_ID = "vm-d05087e5773e4a978036fc806b0cd759";
const CLOUD_VM_ID = "11111111-2222-4333-8444-555555555555";
const TUNNEL_CLIENT_KEY = Buffer.alloc(32, 1).toString("base64");
const EDGE_RULE: VmEdgeRule = {
  domain: "coderouter.dev",
  headers: { "x-cmux-authorization": "Bearer eyJ.signed.token" },
};

// A fake Freestyle SDK client: records every create, exec, file write, and
// delete so the driver's guest-facing behavior can be asserted without a
// platform. `probeExit` is what the edge readiness probe returns.
function fakeFreestyle(input: { readonly probeExit: number; readonly guestCliExit?: number }) {
  const networkData = { publicIpv6: "2602:f75c:0:1::2a", vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }] };
  const creates: unknown[] = [];
  const execs: string[] = [];
  const writes: Array<{ path: string; content: string }> = [];
  const deletes: string[] = [];
  let guestCliProbeSeen = false;
  const vm = {
    exec: async ({ command }: { command: string }) => {
      execs.push(command);
      const statusCode = command.includes("sha256sum") && !guestCliProbeSeen
        ? (guestCliProbeSeen = true, input.guestCliExit ?? 0)
        : command.includes("/api/coderouter/vm-usage/self") ? input.probeExit : 0;
      return { statusCode, stdout: "", stderr: statusCode === 0 ? "" : "probe failed" };
    },
    fs: {
      writeTextFile: async (path: string, content: string) => {
        writes.push({ path, content });
      },
      remove: async () => {},
    },
    delete: async () => {
      deletes.push(VM_ID);
    },
    data: async () => networkData,
    // Every VM boots at its snapshot's resources; create grows it to the plan
    // machine before bootstrap (see growToRequestedSize).
    resize: async () => {},
  };
  const client = {
    vms: {
      create: async (options: unknown) => {
        creates.push(options);
        return { vm, vmId: VM_ID, data: networkData };
      },
      get: async () => ({ resources: { cpu: 2, memory: 4096, storage: 16384 } }),
      ref: () => vm,
    },
  } as unknown as Freestyle;
  return { client, creates, execs, writes, deletes };
}

function providerWith(fake: { readonly client: Freestyle }): FreestyleProvider {
  return new FreestyleProvider({
    client: () => fake.client,
  });
}

describe("FreestyleProvider transport contract", () => {
  test("cmux-remote is the only session transport", () => {
    const provider = new FreestyleProvider();
    expect(provider.attachTransports).toEqual(["cmux-remote"]);
    expect(typeof provider.openCmuxRemote).toBe("function");
    expect(typeof provider.approveCmuxRemoteEnrollment).toBe("function");
  });

  test("legacy attach and public SSH remain unavailable", () => {
    // SSH is an explicit legacy attach verb. It must not become the default
    // transport advertised for cmux-tui machines.
    const provider: VMProvider = new FreestyleProvider();
    expect(provider.openAttach).toBeUndefined();
    expect(provider.openSSH).toBeUndefined();
    expect(provider.revokeSSHIdentity).toBeUndefined();
  });

  test("fork is not implemented, so the capability resolves false", () => {
    // vmCapabilitiesFor() derives `fork` from the method's existence; a machine
    // menu must not offer a verb the driver cannot serve.
    const provider = new FreestyleProvider();
    expect((provider as { fork?: unknown }).fork).toBeUndefined();
  });
});

describe("Freestyle platform contract", () => {
  test("firewall on a private-network machine: outbound only, no inbound at all", () => {
    // The VPC's members-reach-each-other rule is what admits the daemon port;
    // an inbound rule here would re-expose 1337 to the Internet.
    expect(freestyleFirewallRules()).toEqual([
      { action: "allow", source: {}, destination: { public: true } },
    ]);
  });

  test("team VM adds exactly one VPC ingress rule", () => {
    expect(freestyleFirewallRules({ memberIngressNetworkId: "vpc-team" })).toEqual([
      { action: "allow", source: {}, destination: { public: true } },
      { action: "allow", source: { vpcId: "vpc-team" }, destination: {} },
    ]);
  });

  test("firewall without a network: inbound 1337 opens publicly, as before", () => {
    expect(freestyleFirewallRules({ publicDaemonIngress: true })).toEqual([
      { action: "allow", source: {}, destination: { public: true } },
      { action: "allow", source: { public: true }, destination: { port: 1337, protocol: "tcp" } },
    ]);
  });

  test("network firewall: one members-reach-each-other rule, nothing else", () => {
    // No port/protocol matcher: members reach each other on ALL ports. The
    // same rule is re-created by the reuse-path heal if deleted out of band.
    expect(FREESTYLE_NETWORK_FIREWALL_RULES).toEqual([
      { action: "allow", source: {}, destination: {} },
    ]);
  });

  test("create and restore add team ingress only when requested", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    const provider = providerWith(fake);
    await provider.create({ image: "snapshot", network: { id: "vpc-team", memberIngress: true } });
    const teamRules = (fake.creates[0] as { firewall: { rules: unknown[] } }).firewall.rules;
    expect(teamRules.filter((rule) => JSON.stringify(rule).includes("vpc-team"))).toHaveLength(1);
    await provider.create({ image: "snapshot", network: { id: "vpc-team" } });
    const personalRules = (fake.creates[1] as { firewall: { rules: unknown[] } }).firewall.rules;
    expect(personalRules.filter((rule) => JSON.stringify(rule).includes("vpc-team"))).toHaveLength(0);
    await provider.restore("snapshot", { network: { id: "vpc-team", memberIngress: true } });
    const restoreRules = (fake.creates[2] as { firewall: { rules: unknown[] } }).firewall.rules;
    expect(restoreRules.filter((rule) => JSON.stringify(rule).includes("vpc-team"))).toHaveLength(1);
  });

  test("team network creation omits members rule, including slug conflicts", async () => {
    const network = { id: "vpc-team", slug: "team-slug", cidr: "10.1.0.0/24", cidrV6: "fd01::/64" };
    let createCount = 0;
    let createdOptions: unknown;
    const client = {
      vpc: {
        create: async (options: unknown) => { createCount += 1; createdOptions = options; return { data: network }; },
        get: async () => network,
      },
      firewall: { rules: { list: async () => { throw new Error("members heal must not run"); }, create: async () => { throw new Error("members heal must not run"); } } },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    await provider.privateNetworking!.ensureNetwork({ slug: "team-slug", membersRule: false });
    expect(createCount).toBe(1);
    expect(createdOptions).toEqual({ slug: "team-slug", displayName: undefined, firewall: { rules: [] } });
    const conflictClient = {
      ...client,
      vpc: {
        create: async () => { throw new FreestyleApiError(409, { code: "CONFLICT", message: "slug exists" }); },
        get: async () => network,
      },
    } as unknown as Freestyle;
    const conflictProvider = new FreestyleProvider({ client: () => conflictClient });
    await conflictProvider.privateNetworking!.ensureNetwork({ slug: "team-slug", membersRule: false });
  });

  test("team tunnel attach/detach maps addresses and classifies overlap", async () => {
    const attachment = { vpcId: "vpc-team", ipv4: "10.2.0.2", ipv6: "fd02::2" };
    const client = {
      tunnels: {
        attachVpc: async () => ({ attachments: [attachment] }),
        detachVpc: async () => { throw new FreestyleApiError(404, { code: "NOT_FOUND", message: "gone" }); },
      },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    await expect(provider.privateNetworking!.attachTunnelNetwork!("tun-1", "vpc-team")).resolves.toEqual({ networkId: "vpc-team", addressV4: "10.2.0.2", addressV6: "fd02::2" });
    await expect(provider.privateNetworking!.detachTunnelNetwork!("tun-1", "vpc-team")).resolves.toBeUndefined();
    const errorProvider = new FreestyleProvider({ client: () => ({ tunnels: { detachVpc: async () => { throw new Error("detach failed"); } } } as unknown as Freestyle) });
    await expect(errorProvider.privateNetworking!.detachTunnelNetwork!("tun-1", "vpc-team")).rejects.toBeInstanceOf(ProviderError);
    const overlapProvider = new FreestyleProvider({ client: () => ({ tunnels: { attachVpc: async () => { throw new FreestyleApiError(409, { code: "CONFLICT", message: "overlap" }); } } } as unknown as Freestyle) });
    const overlap = await overlapProvider.privateNetworking!.attachTunnelNetwork!("tun-1", "vpc-team").catch((error) => error);
    expect(overlap).toBeInstanceOf(ProviderTunnelNetworkOverlapError);
    expect(isProviderTunnelNetworkOverlap({ cause: overlap })).toBe(true);
  });

  test("create never re-reads or resizes a snapshot-backed machine", async () => {
    const createResponse = (fake: ReturnType<typeof fakeFreestyle>, gets: string[], resizes: unknown[]) => {
      const vm = fake.client.vms.ref(VM_ID);
      vm.resize = (async (request: unknown) => {
        resizes.push(request);
      }) as never;
      fake.client.vms.create = async (options: unknown) => {
        fake.creates.push(options);
        return {
          vm,
          vmId: VM_ID,
          data: {
            publicIpv6: "2602:f75c:0:1::2a",
            vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }],
            resources: { cpu: 2, memory: 4096, storage: 16384 },
          },
        } as never;
      };
      fake.client.vms.get = async (id: string) => {
        gets.push(id);
        throw new Error("create must not read the machine it just created");
      };
    };
    const sizeless = fakeFreestyle({ probeExit: 0 });
    const sizelessGets: string[] = [];
    const sizelessResizes: unknown[] = [];
    createResponse(sizeless, sizelessGets, sizelessResizes);
    await providerWith(sizeless).create({
      image: "sh-image",
      network: { id: "vpc-test-1" },
      memoryMb: 20480,
    } as never);
    expect(sizelessGets).toEqual([]);
    expect(sizelessResizes).toEqual([]);

    const sized = fakeFreestyle({ probeExit: 0 });
    const sizedGets: string[] = [];
    const sizedResizes: unknown[] = [];
    createResponse(sized, sizedGets, sizedResizes);
    await providerWith(sized).create({
      image: "sh-image",
      network: { id: "vpc-test-1" },
      memoryMb: 20480,
      imageSize: { name: "lgx", cpu: 12, memoryMb: 24576, storageMb: 98304 },
    } as never);
    expect(sizedGets).toEqual([]);
    expect(sizedResizes).toEqual([]);
  });

  test("network addresses persist from the create response, absent without a network", () => {
    expect(
      freestyleNetworkAddressMetadata({
        vpcs: [{ ipv4: "10.16.133.3", ipv6: "fd60:1e5e:6720::3" }],
      }),
    ).toEqual({ networkIpv4: "10.16.133.3", networkIpv6: "fd60:1e5e:6720::3" });
    expect(freestyleNetworkAddressMetadata({ vpcs: [] })).toEqual({});
    expect(freestyleNetworkAddressMetadata({ publicIpv6: "2602::1" })).toEqual({});
  });

  test("network metadata drops malformed provider addresses before publication", () => {
    expect(
      freestyleNetworkAddressMetadata({
        vpcs: [{ ipv4: "not-an-ip", ipv6: "fd60:1e5e:6720::3" }],
      }),
    ).toEqual({ networkIpv6: "fd60:1e5e:6720::3" });
    expect(
      freestyleNetworkAddressMetadata({
        vpcs: [{ ipv4: "not-an-ip", ipv6: "also-not-an-ip" }],
      }),
    ).toEqual({});
  });

  test("cmux-remote route prefers the private VPC address and never falls back from it", () => {
    // On a VPC: the private address wins even when a public address exists,
    // because a VPC machine has no public inbound rule. v4 is preferred within
    // the network — the tunnel routes the VPC's v4 prefix as a subnet and so
    // reaches new members immediately, while its v6 path does not pick up VMs
    // created after the tunnel came up, stalling their connect for the full
    // timeout.
    expect(
      freestyleCmuxRemoteRoute(
        {
          publicIpv6: "2602:f75c:0:1::2a",
          vpcs: [{ ipv4: "10.40.0.10", ipv6: "fd7a:115c:a1e0::a" }],
        },
        VM_ID,
      ),
    ).toBe("ws://10.40.0.10:1337/v1/link");
    // v6-only membership is the honest second choice, not a public fallback.
    expect(
      freestyleCmuxRemoteRoute(
        { publicIpv6: "2602:f75c:0:1::2a", vpcs: [{ ipv4: null, ipv6: "fd7a:115c:a1e0::a" }] },
        VM_ID,
      ),
    ).toBe("ws://[fd7a:115c:a1e0::a]:1337/v1/link");
    // A membership with no address is unreachable and must say so, not
    // silently dial a public address the firewall will drop.
    expect(() =>
      freestyleCmuxRemoteRoute(
        { publicIpv6: "2602:f75c:0:1::2a", vpcs: [{ ipv4: null, ipv6: null }] },
        VM_ID,
      ),
    ).toThrow("no address");
  });

  test("cmux-remote route without a network is the public IPv6, as before", () => {
    expect(freestyleCmuxRemoteRoute({ publicIpv6: "2602:f75c:0:1::2a" }, VM_ID)).toBe(
      "ws://[2602:f75c:0:1::2a]:1337/v1/link",
    );
    // The deprecated `networks` alias still resolves for older responses.
    expect(
      freestyleCmuxRemoteRoute(
        { networks: [{ ipv6: "fd7a:115c:a1e0::b" }] },
        VM_ID,
      ),
    ).toBe("ws://[fd7a:115c:a1e0::b]:1337/v1/link");
    expect(() => freestyleCmuxRemoteRoute({ publicIpv6: null }, VM_ID)).toThrow("public IPv6");
    expect(() => freestyleCmuxRemoteRoute({ publicIpv6: "  " }, VM_ID)).toThrow("public IPv6");
  });

  test("edge rules map to inline egress tls rules with header transforms", () => {
    expect(freestyleEdgeRules([EDGE_RULE])).toEqual([
      {
        action: "allow",
        domain: "coderouter.dev",
        source: {},
        destination: { public: true },
        transform: [
          {
            headers: {
              "x-cmux-authorization": "Bearer eyJ.signed.token",
            },
          },
        ],
      },
    ]);
    expect(freestyleEdgeRules(undefined)).toBeUndefined();
    expect(freestyleEdgeRules([])).toBeUndefined();
    expect(() => freestyleEdgeRules([{ ...EDGE_RULE, domain: "coderouter.dev:8443" }])).toThrow(ProviderError);
    expect(() => freestyleEdgeRules([{ ...EDGE_RULE, domain: "x; rm -rf /" }])).toThrow(ProviderError);
  });


  test("exec dispatches directly to the immutable guest CLI", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    const result = await providerWith(fake).exec(VM_ID, "echo hi", { timeoutMs: 5_000 });
    expect(result.exitCode).toBe(0);
    expect(fake.execs).toEqual(["echo hi"]);
    expect(fake.writes).toHaveLength(0);
  });

  test("exec does not repair an absent guest CLI during a command", async () => {
    const fake = fakeFreestyle({ probeExit: 0, guestCliExit: 1 });
    const result = await providerWith(fake).exec(VM_ID, "cmux self --json");
    expect(result.exitCode).toBe(0);
    expect(fake.writes).toHaveLength(0);
    expect(fake.execs).toEqual(["cmux self --json"]);
  });

  test("exec timeouts clamp to the per-exec cap; killed execs read as 124", () => {
    expect(normalizeFreestyleExecTimeout(undefined)).toBe(30_000);
    expect(normalizeFreestyleExecTimeout(-5)).toBe(30_000);
    expect(normalizeFreestyleExecTimeout(10 * 60 * 1000)).toBe(300_000);
    expect(normalizeFreestyleExecTimeout(12_345)).toBe(12_345);
  });

  test("stopped VMs read as paused (start() recovers them), not destroyed", () => {
    expect(mapFreestyleState("starting")).toBe("creating");
    expect(mapFreestyleState("running")).toBe("running");
    expect(mapFreestyleState("pausing")).toBe("paused");
    expect(mapFreestyleState("paused")).toBe("paused");
    expect(mapFreestyleState("stopped")).toBe("paused");
  });

  test("recovers an existing provider tunnel when local bookkeeping is missing", async () => {
    // A fresh local/dev database can lose its tunnel row while the provider
    // resource survives. Re-enrollment must reconcile by the deterministic
    // device slug instead of trying to create a duplicate and returning 502.
    const calls = { create: 0, list: 0, attach: 0 };
    const existing = {
      id: "tun-existing",
      tunnelId: "tun-existing",
      slug: "cmux-wg-recover",
      displayName: "cmux computer",
      clientConfig: "[Interface]\nPrivateKey =\n[Peer]\n",
      endpointHost: "tun-existing.beta-vpn.freestyle.sh",
      endpointPort: 51820,
      clientPublicKey: TUNNEL_CLIENT_KEY,
      serverPublicKey: "server-key",
      clientAddressV4: "100.64.0.2",
      clientAddressV6: "fd00::2",
      routes: ["10.0.0.0/8", "fd00::/8"],
      attachments: [{
        vpcId: "vpc-1",
        ipv4: "10.40.0.2",
        ipv6: "fd00:40::2",
        address: "10.40.0.2",
        vpcCidr: "10.40.0.0/24",
        allowedIps: ["10.40.0.0/24", "fd00:40::/64"],
        createdAt: "2026-01-01T00:00:00.000Z",
      }],
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    const client = {
      tunnels: {
        create: async () => {
          calls.create += 1;
          throw new FreestyleApiError(409, { code: "CONFLICT", message: "slug already exists" });
        },
        list: async () => {
          calls.list += 1;
          return { tunnels: [existing], totalCount: 1 };
        },
        attachVpc: async () => {
          calls.attach += 1;
          return existing;
        },
      },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({
      client: () => client,
    });

    const recovered = await provider.privateNetworking!.createTunnel({
      slug: "cmux-wg-recover",
      displayName: "cmux computer",
      clientPublicKey: TUNNEL_CLIENT_KEY,
      networkId: "vpc-1",
    });

    expect(recovered).toMatchObject({
      tunnel: {
        id: "tun-existing",
        clientPublicKey: TUNNEL_CLIENT_KEY,
        addressV4: "10.40.0.2",
        addressV6: "fd00:40::2",
      },
      created: false,
      rotated: false,
    });
    expect(calls).toEqual({ create: 1, list: 1, attach: 0 });
  });

  // Measured: tunnels.create answered 503 after ~25 s, yet the tunnel existed;
  // only the app's later 409 retry recovered it (30.9 s to a first failure).
  // A create with no answer or a 5xx must look for its own tunnel at once.
  const createFailures: [string, () => Error][] = [
    ["a provider 5xx", () => new FreestyleApiError(503, { code: "INTERNAL_ERROR", message: "upstream" })],
    ["no response (client timeout)", () => new DOMException("The operation timed out.", "TimeoutError")],
  ];
  test.each(createFailures)("recovers the same-key tunnel after %s", async (_label, failure) => {
    const calls = { create: 0, list: 0 };
    const timeouts: (number | undefined)[] = [];
    const tunnel = recoverableTunnel(TUNNEL_CLIENT_KEY);
    const client = {
      tunnels: {
        create: async () => { calls.create += 1; throw failure(); },
        list: async () => { calls.list += 1; return { tunnels: [tunnel], totalCount: 1 }; },
        attachVpc: async () => tunnel,
      },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: (timeoutMs) => { timeouts.push(timeoutMs); return client; } });

    const result = await provider.privateNetworking!.createTunnel({
      slug: "cmux-wg-recover",
      displayName: "cmux computer",
      clientPublicKey: TUNNEL_CLIENT_KEY,
      networkId: "vpc-1",
    });

    expect(result).toMatchObject({ tunnel: { id: "tun-existing" }, created: false, rotated: false });
    expect(calls).toEqual({ create: 1, list: 1 });
    // The create itself runs under a bounded timeout, well inside the route's 30 s.
    expect(timeouts[0]).toBeLessThanOrEqual(10_000);
  });

  test("a 5xx never adopts a tunnel that holds another client's key", async () => {
    const client = {
      tunnels: {
        create: async () => { throw new FreestyleApiError(503, { code: "INTERNAL_ERROR", message: "upstream" }); },
        list: async () => ({ tunnels: [recoverableTunnel("other-client-key")], totalCount: 1 }),
        attachVpc: async () => { throw new Error("must not attach"); },
      },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });

    await expect(provider.privateNetworking!.createTunnel({
      slug: "cmux-wg-recover",
      displayName: "cmux computer",
      clientPublicKey: TUNNEL_CLIENT_KEY,
      networkId: "vpc-1",
    })).rejects.toThrow("createTunnel(cmux-wg-recover)");
  });

  test("a definite 4xx refusal does not spend a recovery read", async () => {
    let lists = 0;
    const client = {
      tunnels: {
        create: async () => { throw new FreestyleApiError(400, { code: "BAD_REQUEST", message: "bad key" }); },
        list: async () => { lists += 1; return { tunnels: [], totalCount: 0 }; },
      },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });

    await expect(provider.privateNetworking!.createTunnel({
      slug: "cmux-wg-recover",
      displayName: "cmux computer",
      clientPublicKey: TUNNEL_CLIENT_KEY,
      networkId: "vpc-1",
    })).rejects.toThrow("createTunnel(cmux-wg-recover)");
    expect(lists).toBe(0);
  });
});

function recoverableTunnel(clientPublicKey: string) {
  return {
    id: "tun-existing",
    tunnelId: "tun-existing",
    slug: "cmux-wg-recover",
    displayName: "cmux computer",
    clientConfig: "[Interface]\nPrivateKey =\n[Peer]\n",
    endpointHost: "tun-existing.beta-vpn.freestyle.sh",
    endpointPort: 51820,
    clientPublicKey,
    serverPublicKey: "server-key",
    clientAddressV4: "100.64.0.2",
    clientAddressV6: "fd00::2",
    routes: ["10.0.0.0/8", "fd00::/8"],
    attachments: [{
      vpcId: "vpc-1",
      ipv4: "10.40.0.2",
      ipv6: "fd00:40::2",
      address: "10.40.0.2",
      vpcCidr: "10.40.0.0/24",
      allowedIps: ["10.40.0.0/24", "fd00:40::/64"],
      createdAt: "2026-01-01T00:00:00.000Z",
    }],
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  };
}

describe("FreestyleProvider create with edge rules", () => {
  test("creates persistent machines with idle pausing disabled", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    await providerWith(fake).create({ image: "sh-devbox" });

    expect(fake.creates[0]).toMatchObject({
      // Cloud machines keep their durable box available until the user
      // explicitly pauses or destroys it. The explicit -1 also overrides a
      // provider/account default that would otherwise idle-pause the VM.
      idleTimeoutSeconds: -1,
    });
  });

  test("passes the rule inline and returns a snapshot-v2 machine without guest setup", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    const handle = await providerWith(fake).create({
      image: "sh-devbox",
      edgeRules: [EDGE_RULE],
    });
    expect(handle.providerVmId).toBe(VM_ID);
    expect(fake.creates).toHaveLength(1);
    expect(fake.creates[0]).toMatchObject({
      snapshotId: "sh-devbox",
      // No network given, so the daemon port stays publicly reachable.
      firewall: { rules: freestyleFirewallRules({ publicDaemonIngress: true }) },
      tls: { rules: freestyleEdgeRules([EDGE_RULE]) },
    });
    expect(fake.creates[0]).not.toHaveProperty("vpcs");
    // The token reaches the platform create call and nothing else.
    expect(JSON.stringify(fake.execs)).not.toContain("crt_");
    expect(fake.writes).toHaveLength(0);
    expect(fake.execs.some((command) => command.includes("/api/coderouter/vm-usage/self"))).toBe(false);
    expect(fake.deletes).toEqual([]);
  });

  test("keeps the inline tls rule when the machine joins a private network", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    const handle = await providerWith(fake).create({
      image: "sh-devbox",
      edgeRules: [EDGE_RULE],
      network: { id: "vpc_1" },
    });
    expect(fake.creates[0]).toMatchObject({
      firewall: { rules: freestyleFirewallRules({ publicDaemonIngress: false }) },
      vpcs: [{ vpcId: "vpc_1", ipv4: true, ipv6: true }],
      tls: { rules: freestyleEdgeRules([EDGE_RULE]) },
    });
    expect(handle.providerMetadata).toMatchObject({ networkId: "vpc_1" });
    expect(fake.writes).toHaveLength(0);
    expect(handle.providerMetadata).toMatchObject({
      networkId: "vpc_1",
      networkIpv4: "10.4.0.7",
      networkIpv6: "fd00:4::7",
    });
    // The guest shim contains a literal `crt_*` rejection guard; the actual
    // edge token must never be copied into guest files.
    expect(JSON.stringify(fake.writes)).not.toContain("crt_secret-token");
  });

  test("omits the tls block and all guest work when no rules are given", async () => {
    const fake = fakeFreestyle({ probeExit: 1 });
    await providerWith(fake).create({ image: "sh-devbox" });
    expect(fake.creates[0]).not.toHaveProperty("tls");
    expect(fake.execs.some((command) => command.includes("/api/coderouter/vm-usage/self"))).toBe(false);
    expect(fake.writes).toHaveLength(0);
  });

  test("restore passes the rule inline without guest setup", async () => {
    const ok = fakeFreestyle({ probeExit: 0 });
    const restored = await providerWith(ok).restore("snap-1", { edgeRules: [EDGE_RULE] });
    expect(restored.image).toBe("snap-1");
    expect(ok.creates[0]).toMatchObject({
      snapshotId: "snap-1",
      idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
      tls: { rules: freestyleEdgeRules([EDGE_RULE]) },
    });
    expect(ok.writes).toHaveLength(0);
    expect(ok.deletes).toEqual([]);
  });
});

// A wake: `start()` reports the machine running, and its payload may or may not
// carry the address the platform assigned it on the private network. `delete`
// and `pause` are recorded so a test can prove the wake rolled nothing back.
function resumeFake(vpcs?: readonly Record<string, unknown>[]) {
  const execs: string[] = [];
  const deletes: string[] = [];
  const pauses: string[] = [];
  const vm = {
    start: async () => ({
      id: VM_ID,
      state: "running" as const,
      snapshotId: "sh-devbox",
      resources: { cpu: 2, memory: 4096, storage: 16384 },
      ...(vpcs === undefined ? {} : { vpcs }),
    }),
    update: async () => ({}),
    exec: async ({ command }: { command: string }) => {
      execs.push(command);
      return { statusCode: 0, stdout: "", stderr: "" };
    },
    delete: async () => {
      deletes.push(VM_ID);
    },
    pause: async () => {
      pauses.push(VM_ID);
    },
  };
  const client = { vms: { ref: () => vm } } as unknown as Freestyle;
  return { client, execs, deletes, pauses };
}

/** The addresses the guest announcement was asked to announce, if it ran. */
function announcedAddresses(execs: readonly string[]): readonly string[] {
  const announcement = execs.find((command) => command.includes("Private network addresses are not ready"));
  const payload = announcement?.match(/'(\[[^\[\]]*\])'$/)?.[1];
  return payload ? (JSON.parse(payload) as string[]) : [];
}

describe("FreestyleProvider resume network readiness", () => {
  test("a wake announces the private addresses its payload carries", async () => {
    const fake = resumeFake([{ vpcId: "vpc_1", ipv4: "10.4.0.7", ipv6: "fd00:4::7" }]);

    const handle = await providerWith(fake).resume(VM_ID);

    expect(handle.status).toBe("running");
    expect(announcedAddresses(fake.execs)).toEqual(["10.4.0.7", "fd00:4::7"]);
  });

  test.each([
    { vpcs: undefined },
    { vpcs: [] },
    { vpcs: [{ vpcId: "vpc_1", routes: [] }] },
    { vpcs: [{ ipv4: "not-an-ip", ipv6: "also-not-an-ip" }] },
  ])("a wake without a usable address still wakes and rolls nothing back: %j", async ({ vpcs }) => {
    // `start()` has already returned, so the machine is running and a resume
    // has no fresh allocation to undo. A start payload can also name the
    // network before the platform fills in the address assigned on it, so a
    // missing address here is not a verdict on the machine. openCmuxRemote
    // reads the authoritative addresses and is the boundary that fails closed.
    const fake = resumeFake(vpcs);

    const handle = await providerWith(fake).resume(VM_ID);

    expect(handle.status).toBe("running");
    expect(announcedAddresses(fake.execs)).toEqual([]);
    expect(fake.deletes).toEqual([]);
    expect(fake.pauses).toEqual([]);
  });
});

describe("FreestyleProvider resume policy", () => {
  test("clears a legacy idle timeout when waking an existing machine", async () => {
    const updates: unknown[] = [];
    const vm = {
      start: async () => ({
        id: VM_ID,
        state: "running" as const,
        snapshotId: "sh-devbox",
        resources: { cpu: 2, memory: 4096, storage: 16384 },
        idleTimeoutSeconds: 3600,
        vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }],
      }),
      update: async (options: unknown) => {
        updates.push(options);
        return {};
      },
      exec: async () => ({ statusCode: 0, stdout: "", stderr: "" }),
    };
    const client = { vms: { ref: () => vm } } as unknown as Freestyle;
    const provider = new FreestyleProvider({
      client: () => client,
    });

    const handle = await provider.resume(VM_ID);

    expect(handle.status).toBe("running");
    expect(updates).toEqual([{ idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS }]);
  });
});

const driverSource = readFileSync(
  path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"),
  "utf8",
);

describe("Freestyle edge rule destination", () => {
  test("an alias rule connects the edge to the deployment's API host; a bare rule stays public", () => {
    const [alias] = freestyleEdgeRules([{ domain: "coderouter.cmux.internal", destinationHost: "cmux.com", headers: { a: "b" } }])!;
    expect(alias).toMatchObject({ domain: "coderouter.cmux.internal", destination: { host: "cmux.com", port: 443 }, transform: [{ headers: { a: "b" } }] });
    const [plain] = freestyleEdgeRules([EDGE_RULE])!;
    expect(plain.destination).toEqual({ public: true });
    expect(() => freestyleEdgeRules([{ domain: "x.dev", destinationHost: "bad host", headers: {} }])).toThrow(ProviderError);
  });
});

describe("Freestyle attach route source", () => {
  test("attach builds the route from the persisted row addresses, falling back to the provider only without them", () => {
    expect(freestyleRouteAddressesFromMetadata({ networkIpv4: "10.0.0.5", networkIpv6: "fd00::5" })).toEqual({ vpcs: [{ ipv4: "10.0.0.5", ipv6: "fd00::5" }] });
    expect(freestyleCmuxRemoteRoute(freestyleRouteAddressesFromMetadata({ networkIpv4: " 10.0.0.5 " })!, VM_ID)).toBe("ws://10.0.0.5:1337/v1/link");
    expect(freestyleRouteAddressesFromMetadata({ networkId: "vpc-1" })).toBeNull();
    expect(freestyleRouteAddressesFromMetadata(undefined)).toBeNull();
  });
});

describe("Freestyle client configuration", () => {
  test("every guest exec is pinned to root", () => {
    // The 0.2 API's linuxUser default is uid 1000, not root. The devbox image
    // ships such a user, so an unpinned exec would silently move the daemon,
    // its install, and the model-plane write off the root layout.
    const execCalls = driverSource.match(/\.exec\(\{[\s\S]*?\}\)/g) ?? [];
    expect(execCalls.length).toBeGreaterThan(0);
    for (const call of execCalls) {
      expect(call).toContain("linuxUser");
    }
  });

  test("the driver talks to the SDK's default public edge unless overridden", () => {
    // No hardcoded beta host, and no baseUrl unless FREESTYLE_API_URL says so.
    expect(driverSource).not.toContain("beta-api.freestyle.sh");
    expect(driverSource).toContain("process.env.FREESTYLE_API_URL");
  });

  test("the beta SDK alias is gone from package.json", () => {
    const packageJson = JSON.parse(
      readFileSync(path.join(import.meta.dirname, "../package.json"), "utf8"),
    ) as { dependencies: Record<string, string> };
    expect(packageJson.dependencies["freestyle-beta"]).toBeUndefined();
    expect(packageJson.dependencies.freestyle).toBe("0.2.10");
  });
});

// The desktop and forwarded ports travel the daemon's private path: the URL
// is the machine's VPC address over the owner's tunnel, nothing is minted at
// the platform and nothing public is opened. noVNC on 6901 has no auth of
// its own, so a machine outside a private network gets no URL at all.
describe("Freestyle openCmuxRemote: snapshot-v2 fast path", () => {
  test("uses persisted network metadata without a guest probe or healing", async () => {
    const commands: string[] = [];
    const vm = {
      exec: async ({ command }: { command: string }) => { commands.push(command); return { statusCode: 0, stdout: "", stderr: "" }; },
    };
    const client = { vms: { ref: () => vm } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    const endpoint = await provider.openCmuxRemote(VM_ID, {
      providerMetadata: { cmuxTuiContract: "snapshot-v2", networkIpv4: "10.4.0.7", networkIpv6: "fd00:4::7" },
    });
    expect(endpoint).toMatchObject({ route: "ws://10.4.0.7:1337/v1/link", trustedCarrier: true });
    expect(commands).toEqual([]);
  });

  // Cloud has not shipped a row from before snapshot-v2, so there is nothing
  // to stay compatible with: a row without the contract or its recorded
  // addresses is refused with a clear error, never healed or looked up.
  for (const [name, providerMetadata] of [
    ["without the snapshot-v2 contract", { networkIpv4: "10.4.0.8" }],
    ["without recorded addresses", { cmuxTuiContract: "snapshot-v2" }],
    ["with no metadata", {}],
  ] as const) {
    test(`a row ${name} is refused without provider reads or guest work`, async () => {
      const commands: string[] = [];
      let reads = 0;
      const vm = {
        data: async () => { reads += 1; return { vpcs: [{ ipv4: "10.4.0.9" }] }; },
        exec: async ({ command }: { command: string }) => { commands.push(command); return { statusCode: 0, stdout: "", stderr: "" }; },
      };
      const client = { vms: { ref: () => vm } } as unknown as Freestyle;
      const provider = new FreestyleProvider({ client: () => client });
      await expect(provider.openCmuxRemote(VM_ID, { providerMetadata })).rejects.toThrow(/recreate/);
      expect(reads).toBe(0);
      expect(commands).toEqual([]);
    });
  }
});

describe("Freestyle port open: the private address, the desktop healed", () => {
  const PRIVATE = { publicIpv6: "2602:f75c:0:1::2a", vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }] };

  /** A fake SDK client for one machine: `data()` answers `input.data`, the desktop heal exec exits `input.healExit`. */
  function portFake(input: { readonly data: unknown; readonly healExit?: number }) {
    const execs: string[] = [];
    const vm = {
      data: async () => input.data,
      exec: async ({ command }: { command: string }) => {
        execs.push(command);
        const exit = command.includes(`systemctl start`) ? (input.healExit ?? 0) : 0;
        return { statusCode: exit, stdout: "", stderr: exit === 0 ? "" : "desktop down" };
      },
    };
    const client = { vms: { ref: () => vm } } as unknown as Freestyle;
    return { provider: new FreestyleProvider({ client: () => client }), execs };
  }

  test("address: private v4, then private v6, never public (the desktop has no auth of its own)", () => {
    expect(freestylePortAddress(PRIVATE, VM_ID)).toBe("10.4.0.7");
    expect(freestylePortAddress({ vpcs: [{ ipv6: "fd00:4::7" }] }, VM_ID)).toBe("fd00:4::7");
    expect(() => freestylePortAddress({ publicIpv6: "2602:f75c:0:1::2a", vpcs: [] }, VM_ID)).toThrow(ProviderError);
    expect(() => freestylePortAddress({ publicIpv6: "2602:f75c:0:1::2a", vpcs: [] }, VM_ID)).toThrow(/not on a private network/);
    expect(() => freestylePortAddress({ vpcs: [{}] }, VM_ID)).toThrow(/holds no address/);
    // The deprecated `networks` alias still counts.
    expect(freestylePortAddress({ networks: [{ ipv4: "10.4.0.9" }] }, VM_ID)).toBe("10.4.0.9");
  });

  test("urls: the desktop port opens the noVNC page with a query to extend; other ports the bare origin", () => {
    expect(freestylePortUrls(PRIVATE, VM_ID, DEVBOX_DESKTOP_NOVNC_PORT)).toEqual({
      url: "http://10.4.0.7:6901/",
      openUrl: "http://10.4.0.7:6901/vnc.html?path=websockify",
    });
    expect(freestylePortUrls(PRIVATE, VM_ID, 3000)).toEqual({ url: "http://10.4.0.7:3000/", openUrl: "http://10.4.0.7:3000/" });
    expect(freestylePortUrls({ vpcs: [{ ipv6: "fd00:4::7" }] }, VM_ID, 3000).url).toBe("http://[fd00:4::7]:3000/");
  });

  test("the desktop heal blocks on the unit's readiness signal, never a sleep loop, and tells a base image apart", () => {
    const command = freestyleDesktopHealCommand();
    expect(command).toBe(
      "[ -x /usr/local/bin/start-vnc.sh ] || exit 3; if [ -d /run/systemd/system ]; then systemctl start cmux-desktop || exit 1; fi; ss -tln 2>/dev/null | grep -q ':6901 '",
    );
    expect(command).not.toContain("sleep");
    expect(command).not.toContain("seq ");
  });

  test("openPort(6901) heals the desktop, returns the private noVNC URL and a ledger-only token with the lease TTL", async () => {
    const fake = portFake({ data: PRIVATE });
    const now = new Date("2026-09-03T00:00:00.000Z");
    setSystemTime(now);
    try {
      const endpoint = await fake.provider.openPort(VM_ID, DEVBOX_DESKTOP_NOVNC_PORT);
      expect(endpoint.url).toBe("http://10.4.0.7:6901/");
      expect(endpoint.openUrl).toBe("http://10.4.0.7:6901/vnc.html?path=websockify");
      expect(endpoint.token).toMatch(/^cmux-freestyle-port-[0-9a-f]{64}$/);
      expect(endpoint.expiresAtMs).toBe(now.getTime() + PORT_OPEN_LEASE_TTL_SECONDS * 1000);
      expect(fake.execs).toEqual([freestyleDesktopHealCommand()]);
    } finally {
      setSystemTime();
    }
  });

  test("openPort for a dev server port runs no guest command at all", async () => {
    const fake = portFake({ data: PRIVATE });
    const endpoint = await fake.provider.openPort(VM_ID, 3000);
    expect(endpoint.openUrl).toBe("http://10.4.0.7:3000/");
    expect(fake.execs).toEqual([]);
  });

  test("openPort refuses a machine outside a private network, the daemon port, and a base image", async () => {
    await expect(portFake({ data: { publicIpv6: "2602:f75c:0:1::2a", vpcs: [] } }).provider.openPort(VM_ID, DEVBOX_DESKTOP_NOVNC_PORT))
      .rejects.toThrow(/not on a private network/);
    await expect(portFake({ data: PRIVATE }).provider.openPort(VM_ID, 1337)).rejects.toThrow(/other than the daemon/);
    await expect(portFake({ data: PRIVATE }).provider.openPort(VM_ID, 0)).rejects.toThrow(ProviderError);
    await expect(portFake({ data: PRIVATE, healExit: 3 }).provider.openPort(VM_ID, DEVBOX_DESKTOP_NOVNC_PORT))
      .rejects.toThrow(/has no desktop/);
    await expect(portFake({ data: PRIVATE, healExit: 1 }).provider.openPort(VM_ID, DEVBOX_DESKTOP_NOVNC_PORT))
      .rejects.toThrow(/did not come up on port 6901/);
  });
});

describe("Go provider runtime ceiling", () => {
  test("sets a lifetime cap at create so traffic cannot restart an exhausted VM", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    await providerWith(fake).create({ image: "snapshot-small", runtimeBudgetSeconds: 144000,
      imageSize: { name: "sm", cpu: 2, memoryMb: 4096, storageMb: 16384 } });
    expect(fake.creates[0]).toMatchObject({ maxRunTotalSeconds: 144000, automaticRestart: false });
  });
  test("a resume adds only the remaining billing-period allowance to prior provider runtime", async () => {
    const updates: unknown[] = [];
    const client = { vms: { ref: () => ({ data: async () => ({ totalRunSeconds: 3600 }), update: async (value: unknown) => { updates.push(value); } }) } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    await provider.setRuntimeBudget(VM_ID, 1800);
    await provider.setRuntimeBudget(VM_ID, 0);
    await provider.setRuntimeBudget(VM_ID, null);
    expect(updates).toEqual([
      { maxRunTotalSeconds: 5400, automaticRestart: false },
      { maxRunTotalSeconds: 3600, automaticRestart: false },
      { maxRunTotalSeconds: -1, automaticRestart: true },
    ]);
  });
  test("missing provider runtime fails closed", async () => {
    let updated = false;
    const client = { vms: { ref: () => ({ data: async () => ({}), update: async () => { updated = true; } }) } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    await expect(provider.setRuntimeBudget(VM_ID, 1800)).rejects.toThrow("setRuntimeBudget");
    expect(updated).toBe(false);
  });
});
