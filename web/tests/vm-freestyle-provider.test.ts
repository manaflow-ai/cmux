import { readFileSync } from "node:fs";
import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH } from "../services/vms/guestCli";
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
  freestyleDaemonHealthyCommand,
  freestyleDesktopHealCommand,
  freestyleEdgeRules,
  freestyleFirewallRules,
  freestylePortAddress,
  freestylePortUrls,
  freestyleResizeRequest,
  freestyleStartDaemonCommand,
  freestyleTargetResources,
  mapFreestyleState,
  normalizeFreestyleExecTimeout,
  freestylePinCheckCommand,
} from "../services/vms/drivers/freestyle";
import type { VMProvider } from "../services/vms/drivers/types";
import { cmuxTuiPinCheckCommand } from "../services/vms/drivers/cmuxTuiDaemon";
import { ProviderError, type VmEdgeRule } from "../services/vms/drivers/types";
import { DEVBOX_DESKTOP_NOVNC_PORT } from "../services/vms/images/desktop";

const VM_ID = "vm-d05087e5773e4a978036fc806b0cd759";
const CLOUD_VM_ID = "11111111-2222-4333-8444-555555555555";
const TUNNEL_CLIENT_KEY = Buffer.alloc(32, 1).toString("base64");
const EDGE_RULE: VmEdgeRule = {
  domain: "coderouter.dev",
  headers: { "x-coderouter-route-token": "crt_secret-token", "x-cmux-vm-id": CLOUD_VM_ID },
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
  const vm = {
    exec: async ({ command }: { command: string }) => {
      execs.push(command);
      const statusCode = command.includes("sha256sum") ? (input.guestCliExit ?? 0)
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
    resolveDaemonSource: async () => ({
      url: "https://files.cmux.com/cmux-tui/abc/cmux-tui-linux-x64",
      sha256: "0".repeat(64),
      commit: "abc",
      builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64),
    }),
  });
}

describe("FreestyleProvider transport contract", () => {
  test("cmux-remote is the only session transport", () => {
    const provider = new FreestyleProvider();
    expect(provider.attachTransports).toEqual(["cmux-remote"]);
    expect(typeof provider.openCmuxRemote).toBe("function");
    expect(typeof provider.approveCmuxRemoteEnrollment).toBe("function");
  });

  test("openAttach/openSSH are structurally absent, not throwing stubs", () => {
    // Capability derivation reads method presence; the gateway maps an absent
    // method to VmOperationUnsupportedError (501), so a throwing stub would
    // only turn an honest 501 into a retryable-looking 502.
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

  test("create sizes from the create response and never re-reads the machine", async () => {
    // vms.create already returns the machine's resources; a status read after
    // it cost ~100 ms on every prod create for nothing. A size-less image is
    // the one path that still grows the machine, and it grows from the create
    // response; a sized image boots at its shape and is neither read nor grown.
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
    expect(sizelessResizes).toHaveLength(1);

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

  test("daemon health requires a v6-table listener; start installs the dual-stack override", () => {
    // 0x0539 = 1337; a 0.0.0.0-bound daemon appears only in /proc/net/tcp and
    // is unreachable at the public IPv6, so it must be restarted.
    expect(freestyleDaemonHealthyCommand()).toContain("/proc/net/tcp6");
    expect(freestyleDaemonHealthyCommand()).toContain(":0539 ");
    const start = freestyleStartDaemonCommand();
    expect(start).toContain("Environment=CMUX_TUI_REMOTE_WS_BIND=[::]:1337");
    expect(start).toContain("Environment=CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER=1");
    expect(start).toContain("systemctl restart cmux-tui-daemon");
    expect(start).toContain("--remote-ws [::]:1337"); // non-systemd fallback
    expect(start).toContain("--remote-ws-trusted-carrier");
  });

  test("pin check trusts the pin recorded at bake time, falling back to the live pin on older images", () => {
    const source = { url: "https://files.cmux.com/x", sha256: "f".repeat(64), commit: "abc", builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64) };
    const check = freestylePinCheckCommand(source);
    expect(check).toContain("if [ -s /etc/cmux/cmux-tui-pin ]; then");
    expect(check).toContain("cut -d' ' -f1 /etc/cmux/cmux-tui-pin");
    expect(check).toContain(`else ${cmuxTuiPinCheckCommand(source)}; fi`);
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
              "x-coderouter-route-token": "crt_secret-token",
              "x-cmux-vm-id": CLOUD_VM_ID,
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


  test("exec preserves an up-to-date full guest CLI without uploading it", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    const result = await providerWith(fake).exec(VM_ID, "echo hi", { timeoutMs: 5_000 });
    expect(result.exitCode).toBe(0);
    expect(fake.execs).toHaveLength(2);
    const command = fake.execs[0] ?? "";
    expect(command).toContain(`sha256sum '${GUEST_CMUX_SHIM_PATH}'`);
    expect(fake.execs[1]).toBe("echo hi");
    expect(fake.writes).toHaveLength(0);
    expect(command).not.toContain("crt_");
  });

  test("exec upgrades an absent or outdated guest CLI before running the command", async () => {
    const fake = fakeFreestyle({ probeExit: 0, guestCliExit: 1 });
    const result = await providerWith(fake).exec(VM_ID, "cmux self --json");
    expect(result.exitCode).toBe(0);
    expect(fake.writes).toHaveLength(1);
    expect(fake.writes[0]?.content).toBe(GUEST_CMUX_SHIM);
    expect(fake.execs[1]).toContain(`mv -f`);
    expect(fake.execs.at(-1)).toBe("cmux self --json");
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
      resolveDaemonSource: async () => ({
        url: "https://files.cmux.com/cmux-tui/abc/cmux-tui-linux-x64",
        sha256: "0".repeat(64),
        commit: "abc",
        builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64),
      }),
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
});

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

  test("passes the rule inline, installs only the guest adapter, and returns the machine", async () => {
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
    // The token reaches the platform create call and nothing else. The guest
    // adapter itself is safe to write because it contains no issued token.
    expect(JSON.stringify(fake.execs)).not.toContain("crt_");
    expect(fake.writes).toHaveLength(1);
    expect(fake.writes[0]?.path).toMatch(/^\/usr\/local\/bin\/cmux\.tmp-[0-9a-f]{24}$/);
    expect(fake.writes[0]?.content).toContain("cmux auth status");
    expect(fake.writes[0]?.content).not.toContain("crt_secret-token");
    expect(fake.execs.some((command) => command.includes("mv -f") && command.includes("/usr/local/bin/cmux'"))).toBe(true);
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
    expect(fake.writes).toHaveLength(1);
    expect(fake.writes[0]?.path).toMatch(/^\/usr\/local\/bin\/cmux\.tmp-[0-9a-f]{24}$/);
    expect(fake.execs.some((command) => command.includes("mv -f") && command.includes("/usr/local/bin/cmux'"))).toBe(true);
    expect(fake.writes[0]?.content).not.toContain("crt_secret-token");
    expect(handle.providerMetadata).toMatchObject({
      networkId: "vpc_1",
      networkIpv4: "10.4.0.7",
      networkIpv6: "fd00:4::7",
    });
    // The guest shim contains a literal `crt_*` rejection guard; the actual
    // edge token must never be copied into guest files.
    expect(JSON.stringify(fake.writes)).not.toContain("crt_secret-token");
  });

  test("omits the tls block and the probe when no rules are given", async () => {
    const fake = fakeFreestyle({ probeExit: 1 });
    await providerWith(fake).create({ image: "sh-devbox" });
    expect(fake.creates[0]).not.toHaveProperty("tls");
    expect(fake.execs.some((command) => command.includes("/api/coderouter/vm-usage/self"))).toBe(false);
    expect(fake.writes).toHaveLength(1);
    expect(fake.writes[0]?.path).toMatch(/^\/usr\/local\/bin\/cmux\.tmp-[0-9a-f]{24}$/);
  });

  test("restore passes the rule inline and installs the guest adapter", async () => {
    const ok = fakeFreestyle({ probeExit: 0 });
    const restored = await providerWith(ok).restore("snap-1", { edgeRules: [EDGE_RULE] });
    expect(restored.image).toBe("snap-1");
    expect(ok.creates[0]).toMatchObject({
      snapshotId: "snap-1",
      idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
      tls: { rules: freestyleEdgeRules([EDGE_RULE]) },
    });
    expect(ok.writes).toHaveLength(1);
    expect(ok.writes[0]?.path).toMatch(/^\/usr\/local\/bin\/cmux\.tmp-[0-9a-f]{24}$/);
    expect(ok.writes[0]?.content).not.toContain("crt_secret-token");
    expect(ok.execs.some((command) => command.includes("mv -f") && command.includes("/usr/local/bin/cmux'"))).toBe(true);
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
      resolveDaemonSource: async () => ({
        url: "https://files.cmux.com/cmux-tui/abc/cmux-tui-linux-x64",
        sha256: "0".repeat(64),
        commit: "abc",
        builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64),
      }),
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

describe("Freestyle machine sizing", () => {
  test("the plan machine is 5 vCPU / 20 GB / 32 GB, vCPUs following memory", () => {
    expect(freestyleTargetResources(20480, {})).toEqual({ cpu: 5, memory: 20480, storage: 32768 });
    expect(freestyleTargetResources(8192, {})).toEqual({ cpu: 2, memory: 8192, storage: 32768 });
    expect(freestyleTargetResources(4096, { CMUX_VM_DISK_MB: "65536" })).toEqual({
      cpu: 1,
      memory: 4096,
      storage: 65536,
    });
  });

  test("resize grows the devbox snapshot size to the plan machine", () => {
    // Every VM boots at its snapshot's resources; the devbox snapshot is
    // 2 vCPU / 4 GB / 16 GB, so a fresh create must grow all three.
    expect(freestyleResizeRequest(
      { cpu: 2, memory: 4096, storage: 16384 },
      { cpu: 5, memory: 20480, storage: 32768 },
    )).toEqual({ cpu: 5, memory: 20480, storage: 32768 });
  });

  test("resize is grow-only and sends only the dimensions that grow", () => {
    // A snapshot taken from an already-sized machine restores at that size:
    // nothing to do. A snapshot larger than the request is never shrunk.
    expect(freestyleResizeRequest(
      { cpu: 5, memory: 20480, storage: 204800 },
      { cpu: 5, memory: 20480, storage: 204800 },
    )).toBeNull();
    expect(freestyleResizeRequest(
      { cpu: 8, memory: 32768, storage: 262144 },
      { cpu: 5, memory: 20480, storage: 204800 },
    )).toBeNull();
    expect(freestyleResizeRequest(
      { cpu: 5, memory: 20480, storage: 16384 },
      { cpu: 5, memory: 20480, storage: 204800 },
    )).toEqual({ storage: 204800 });
  });
});

// The desktop and forwarded ports travel the daemon's private path: the URL
// is the machine's VPC address over the owner's tunnel, nothing is minted at
// the platform and nothing public is opened. noVNC on 6901 has no auth of
// its own, so a machine outside a private network gets no URL at all.
describe("Freestyle openCmuxRemote: the trusted-listener heal", () => {
  const PRIVATE = { publicIpv6: "2602:f75c:0:1::2a", vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }] };
  const SOURCE_OK = { url: "https://files.cmux.com/cmux-tui/abc/cmux-tui-linux-x64", sha256: "0".repeat(64), commit: "abc", builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64) };

  /** The attach bundle's fenced stdout with the trusted-listener probe printing `trusted`. */
  function bundleStdout(trusted: "0" | "1"): string {
    return [
      "__CMUX_PROBE__",
      JSON.stringify({ build_identity: "abc", remote_protocol: 12, version: "0.1.0" }),
      "__CMUX_DEVICES__",
      "[]",
      "__CMUX_TRUSTED__",
      trusted,
      "__CMUX_END__",
    ].join("\n");
  }

  /**
   * A fake machine whose attach bundle answers `trusted[n]` on its n-th run.
   * Every other exec (pin check, daemon restart, readiness status) succeeds.
   */
  function attachFake(input: { readonly trusted: readonly ("0" | "1")[]; readonly manifest: "ok" | "down" }) {
    const execs: string[] = [];
    let bundles = 0;
    const vm = {
      data: async () => PRIVATE,
      exec: async ({ command }: { command: string }) => {
        execs.push(command);
        if (command.includes("__CMUX_PROBE__")) {
          const trusted = input.trusted[Math.min(bundles, input.trusted.length - 1)] ?? "0";
          bundles += 1;
          return { statusCode: 0, stdout: bundleStdout(trusted), stderr: "" };
        }
        return { statusCode: 0, stdout: "", stderr: "" };
      },
    };
    const client = { vms: { ref: () => vm } } as unknown as Freestyle;
    const provider = new FreestyleProvider({
      client: () => client,
      resolveDaemonSource: async () => {
        if (input.manifest === "down") throw new Error("manifest fetch failed");
        return SOURCE_OK;
      },
    });
    return { provider, execs, bundles: () => bundles };
  }

  test("a daemon that already serves the trusted listener attaches without reading the manifest", async () => {
    const fake = attachFake({ trusted: ["1"], manifest: "down" });
    const endpoint = await fake.provider.openCmuxRemote(VM_ID, { clientCapabilities: [] });
    expect(endpoint.trustedCarrier).toBe(true);
    expect(endpoint.route).toBe("ws://10.4.0.7:1337/v1/link");
    expect(fake.bundles()).toBe(1);
    expect(fake.execs.some((command) => command.includes("systemctl restart cmux-tui-daemon"))).toBe(false);
  });

  test("an older daemon is replaced with the pinned build and the retried bundle proves trusted mode", async () => {
    const fake = attachFake({ trusted: ["0", "1"], manifest: "ok" });
    const endpoint = await fake.provider.openCmuxRemote(VM_ID, { clientCapabilities: [] });
    expect(endpoint.trustedCarrier).toBe(true);
    expect(fake.bundles()).toBe(2);
    const start = fake.execs.find((command) => command.includes("systemctl restart cmux-tui-daemon"));
    expect(start).toBeDefined();
    // The heal replaces a fallback daemon rather than keeping the untrusted one.
    expect(start).toContain("pkill -f 'cmux-tui server [s]tart'");
  });

  test("a heal that leaves the daemon untrusted fails closed instead of returning an unusable endpoint", async () => {
    const fake = attachFake({ trusted: ["0", "0"], manifest: "ok" });
    await expect(fake.provider.openCmuxRemote(VM_ID, { clientCapabilities: [] })).rejects.toThrow(ProviderError);
    await expect(fake.provider.openCmuxRemote(VM_ID, { clientCapabilities: [] })).rejects.toThrow(/still refuses the trusted listener/);
  });
});

describe("Freestyle openCmuxRemote: agent hooks on a healthy daemon", () => {
  const PRIVATE = { publicIpv6: "2602:f75c:0:1::2a", vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }] };
  const PIN_COMMIT = "5a4780614cecd8e8ef040a24478f928ef31cc4ae";
  const SOURCE = { url: "https://files.cmux.com/cmux-tui/abc/cmux-tui-linux-x64", sha256: "0".repeat(64), commit: PIN_COMMIT, builtAt: null, hookUrl: `https://files.cmux.com/cmux-tui/${PIN_COMMIT}/cmux-tui-hook-x86_64-unknown-linux-musl`, hookSha256: "1".repeat(64) };

  /**
   * A machine whose daemon is healthy and trusted; `hooksReady` is what the
   * hooks-ready probe exits, `pin` what /etc/cmux/cmux-tui-pin holds. Records
   * every manifest URL the driver resolved.
   */
  function hooksFake(input: { readonly hooksReady: number; readonly pin: string; readonly manifest?: "ok" | "missing-helper" }) {
    const execs: string[] = [];
    const manifests: (string | undefined)[] = [];
    const vm = {
      data: async () => PRIVATE,
      exec: async ({ command }: { command: string }) => {
        execs.push(command);
        if (command.includes("__CMUX_PROBE__")) {
          return { statusCode: 0, stdout: ["__CMUX_PROBE__", JSON.stringify({ build_identity: "abc", remote_protocol: 12, version: "0.1.0" }), "__CMUX_DEVICES__", "[]", "__CMUX_TRUSTED__", "1", "__CMUX_END__"].join("\n"), stderr: "" };
        }
        if (command.includes("cmux-tui-pin")) return { statusCode: 0, stdout: `${input.pin}\n`, stderr: "" };
        if (command.includes(".local/share/cmux-tui/bin/cmux-tui-hook") && !command.includes("agent hook install")) {
          return { statusCode: input.hooksReady, stdout: "", stderr: "" };
        }
        return { statusCode: 0, stdout: "", stderr: "" };
      },
    };
    const client = { vms: { ref: () => vm } } as unknown as Freestyle;
    const provider = new FreestyleProvider({
      client: () => client,
      resolveDaemonSource: async (_provider, manifestUrl) => {
        manifests.push(manifestUrl);
        if (input.manifest === "missing-helper") throw new ProviderError("freestyle", "manifest has no cmux-tui-hook");
        return SOURCE;
      },
    });
    return { provider, execs, manifests };
  }

  test("a healthy daemon with hooks already installed is left alone", async () => {
    const fake = hooksFake({ hooksReady: 0, pin: PIN_COMMIT });
    await fake.provider.openCmuxRemote(VM_ID, { clientCapabilities: [] });
    expect(fake.execs.some((command) => command.includes("agent hook install"))).toBe(false);
    expect(fake.manifests).toEqual([]);
  });

  test("a healthy daemon without hooks gets the helper of its own pinned commit and the Claude Code and Codex hooks, with no restart", async () => {
    const fake = hooksFake({ hooksReady: 1, pin: PIN_COMMIT });
    await fake.provider.openCmuxRemote(VM_ID, { clientCapabilities: [] });
    // The bake's pin, not the rolling pointer: helper and daemon share a generation.
    expect(fake.manifests).toEqual([`https://files.cmux.com/cmux-tui/${PIN_COMMIT}/manifest.json`]);
    const install = fake.execs.find((command) => command.includes("agent hook install claude codex"));
    expect(install).toBeDefined();
    expect(install).toContain(SOURCE.hookUrl);
    expect(install).not.toContain(SOURCE.url);
    expect(fake.execs.some((command) => command.includes("systemctl restart cmux-tui-daemon"))).toBe(false);
  });

  test("a machine created from the live pin (no pin file) takes the live manifest", async () => {
    const fake = hooksFake({ hooksReady: 1, pin: "" });
    await fake.provider.openCmuxRemote(VM_ID, { clientCapabilities: [] });
    expect(fake.manifests).toEqual([undefined]);
    expect(fake.execs.some((command) => command.includes("agent hook install claude codex"))).toBe(true);
  });

  test("a daemon that only needed a restart still gets its hooks, and a hook failure never fails the heal", async () => {
    // The first attach bundle reports the daemon not ready (exit 3); the heal
    // finds the pin intact, restarts, and must still reconcile hooks. The hook
    // install itself fails here, and the attach still returns its route.
    const execs: string[] = [];
    let bundles = 0;
    const vm = {
      data: async () => PRIVATE,
      fs: { writeTextFile: async () => {}, remove: async () => {} },
      exec: async ({ command }: { command: string }) => {
        execs.push(command);
        if (command.includes("__CMUX_PROBE__")) {
          bundles += 1;
          if (bundles === 1) return { statusCode: 3, stdout: "", stderr: "" };
          return { statusCode: 0, stdout: ["__CMUX_PROBE__", JSON.stringify({ build_identity: "abc", remote_protocol: 12, version: "0.1.0" }), "__CMUX_DEVICES__", "[]", "__CMUX_TRUSTED__", "1", "__CMUX_END__"].join("\n"), stderr: "" };
        }
        if (command.includes("agent hook install")) return { statusCode: 1, stdout: "", stderr: "helper download failed" };
        if (command.includes("cmux-tui-pin")) return { statusCode: 0, stdout: `${PIN_COMMIT}\n`, stderr: "" };
        if (command.includes(".local/share/cmux-tui/bin/cmux-tui-hook")) return { statusCode: 1, stdout: "", stderr: "" };
        if (command.includes("pgrep -f 'cmux-tui server [s]tart'") && !command.includes("systemctl restart")) return { statusCode: 1, stdout: "", stderr: "" };
        return { statusCode: 0, stdout: "", stderr: "" };
      },
    };
    const client = { vms: { ref: () => vm } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client, resolveDaemonSource: async () => SOURCE });
    const endpoint = await provider.openCmuxRemote(VM_ID, { clientCapabilities: [] });
    expect(endpoint.trustedCarrier).toBe(true);
    expect(execs.some((command) => command.includes("systemctl restart cmux-tui-daemon"))).toBe(true);
    expect(execs.some((command) => command.includes("agent hook install claude codex"))).toBe(true);
  });

  test("a pinned build published before the helper existed still attaches, without hooks", async () => {
    const fake = hooksFake({ hooksReady: 1, pin: PIN_COMMIT, manifest: "missing-helper" });
    const endpoint = await fake.provider.openCmuxRemote(VM_ID, { clientCapabilities: [] });
    expect(endpoint.trustedCarrier).toBe(true);
    expect(fake.execs.some((command) => command.includes("agent hook install"))).toBe(false);
  });
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
    return { provider: new FreestyleProvider({ client: () => client, resolveDaemonSource: async () => { throw new Error("unused"); } }), execs };
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
    const provider = new FreestyleProvider({ client: () => client, resolveDaemonSource: async () => { throw new Error("unused"); } });
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
    const provider = new FreestyleProvider({ client: () => client, resolveDaemonSource: async () => { throw new Error("unused"); } });
    await expect(provider.setRuntimeBudget(VM_ID, 1800)).rejects.toThrow("setRuntimeBudget");
    expect(updated).toBe(false);
  });
});
