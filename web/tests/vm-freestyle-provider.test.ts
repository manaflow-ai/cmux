import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, setSystemTime, test } from "bun:test";
import type { Freestyle } from "freestyle";
import {
  FREESTYLE_NETWORK_FIREWALL_RULES,
  FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
  FreestyleProvider,
  PORT_OPEN_LEASE_TTL_SECONDS,
  assertNoRouteTokenInGuestPayload,
  createOrReuseFreestyleTunnel,
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
  recoverFreestyleTunnelAfterConflict,
  renderFreestyleModelPlaneEnvFile,
} from "../services/vms/drivers/freestyle";
import { FreestyleApiError } from "freestyle";
import { cmuxTuiPinCheckCommand } from "../services/vms/drivers/cmuxTuiDaemon";
import { ProviderError, type VmEdgeRule } from "../services/vms/drivers/types";
import { DEVBOX_DESKTOP_NOVNC_PORT } from "../services/vms/images/desktop";

const VM_ID = "vm-d05087e5773e4a978036fc806b0cd759";
const CLOUD_VM_ID = "11111111-2222-4333-8444-555555555555";
const EDGE_RULE: VmEdgeRule = {
  domain: "coderouter.dev",
  headers: { "x-coderouter-route-token": "crt_secret-token", "x-cmux-vm-id": CLOUD_VM_ID },
};

function tunnelApiData(overrides: Partial<{
  tunnelId: string;
  clientPublicKey: string;
  attachments: Array<{
    vpcId: string;
    ipv4: string;
    ipv6: string;
    address: string;
    vpcCidr: string;
    allowedIps: string[];
    createdAt: string;
  }>;
}> = {}) {
  return {
    id: overrides.tunnelId ?? "tun-test-1",
    tunnelId: overrides.tunnelId ?? "tun-test-1",
    slug: "cmux-wg-test",
    displayName: "cmux computer",
    clientConfig: "[Interface]\nPrivateKey =\n[Peer]\n",
    clientPublicKey: overrides.clientPublicKey ?? "client-key-a",
    serverPublicKey: "server-key",
    endpointHost: "vpn.freestyle.sh",
    endpointPort: 51820,
    clientAddressV4: "100.64.0.2",
    clientAddressV6: "fd7a:7570:6c6b::2",
    routes: ["10.0.0.0/8", "fd00::/8"],
    attachments: overrides.attachments ?? [],
    createdAt: "2026-09-02T00:00:00.000Z",
    updatedAt: "2026-09-02T00:00:00.000Z",
  };
}

function tunnelAttachment(vpcId = "vpc-test-1") {
  return {
    vpcId,
    ipv4: "10.40.0.2",
    ipv6: "fd00:40::2",
    address: "fd00:40::2",
    vpcCidr: "fd00:40::/64",
    allowedIps: ["10.40.0.0/24", "fd00:40::/64"],
    createdAt: "2026-09-02T00:00:00.000Z",
  };
}

const tunnelCreateOptions = {
  slug: "cmux-wg-test",
  displayName: "cmux computer",
  clientPublicKey: "client-key-b",
  networkId: "vpc-test-1",
};

describe("Freestyle tunnel create recovery", () => {
  test("reconciles a provider slug conflict without creating a second tunnel", async () => {
    const calls: string[] = [];
    let existing = tunnelApiData({ clientPublicKey: tunnelCreateOptions.clientPublicKey });
    const api = {
      create: async () => {
        throw new FreestyleApiError(409, { code: "CONFLICT", message: "slug is already in use" });
      },
      get: async (id: string) => {
        calls.push(`get:${id}`);
        return existing;
      },
      attachVpc: async (id: string, vpc: string) => {
        calls.push(`attach:${id}:${vpc}`);
        existing = { ...existing, attachments: [tunnelAttachment(vpc)] };
        return existing;
      },
      rotateKey: async () => {
        throw new Error("must not rotate an equal key");
      },
    };

    const result = await createOrReuseFreestyleTunnel(api, tunnelCreateOptions);
    expect(result.created).toBe(false);
    expect(result.rotated).toBe(false);
    expect(result.tunnel.id).toBe("tun-test-1");
    expect(result.tunnel.addressV4).toBe("10.40.0.2");
    expect(calls).toEqual([
      "get:cmux-wg-test",
      "attach:cmux-wg-test:vpc-test-1",
      "get:cmux-wg-test",
    ]);
  });

  test("attaches the requested VPC before rotating a stale client key", async () => {
    const calls: string[] = [];
    let existing = tunnelApiData({
      clientPublicKey: "client-key-a",
      attachments: [tunnelAttachment("vpc-old")],
    });
    const api = {
      create: async () => {
        throw new FreestyleApiError(409, { code: "CONFLICT", message: "slug is already in use" });
      },
      get: async () => existing,
      attachVpc: async (_id: string, vpc: string) => {
        calls.push(`attach:${vpc}`);
        existing = { ...existing, attachments: [...existing.attachments, tunnelAttachment(vpc)] };
        return existing;
      },
      rotateKey: async (_id: string, options: { clientPublicKey?: string }) => {
        const key = options.clientPublicKey ?? "";
        calls.push(`rotate:${key}`);
        existing = {
          ...existing,
          clientPublicKey: key,
          attachments: [...existing.attachments, tunnelAttachment("vpc-test-1")],
        };
        return existing;
      },
    };

    const result = await createOrReuseFreestyleTunnel(api, tunnelCreateOptions);
    expect(result.created).toBe(false);
    expect(result.rotated).toBe(true);
    expect(result.tunnel.clientPublicKey).toBe(tunnelCreateOptions.clientPublicKey);
    expect(calls).toEqual([
      "attach:vpc-test-1",
      "rotate:client-key-b",
    ]);
  });

  test("keeps the ordinary create path unchanged", async () => {
    const calls: string[] = [];
    const api = {
      create: async (options: {
        slug?: string;
        displayName?: string;
        clientPublicKey?: string;
        routes?: string[];
        vpcs?: { vpcId?: string; vpc?: string }[];
      }) => {
        calls.push(`create:${options.slug}`);
        return tunnelApiData({
          clientPublicKey: options.clientPublicKey,
          attachments: [tunnelAttachment("vpc-test-1")],
        });
      },
      get: async () => {
        throw new Error("must not read after a successful create");
      },
      attachVpc: async () => {
        throw new Error("must not attach after a successful create");
      },
      rotateKey: async () => {
        throw new Error("must not rotate after a successful create");
      },
    };

    const result = await createOrReuseFreestyleTunnel(api, tunnelCreateOptions);
    expect(result.created).toBe(true);
    expect(result.rotated).toBe(false);
    expect(calls).toEqual(["create:cmux-wg-test"]);
  });

  test("does not hide non-conflict provider failures", async () => {
    const failure = new FreestyleApiError(503, { code: "UNAVAILABLE", message: "provider is down" });
    const api = {
      create: async () => {
        throw failure;
      },
      get: async () => tunnelApiData(),
      attachVpc: async () => tunnelApiData(),
      rotateKey: async () => tunnelApiData(),
    };
    await expect(createOrReuseFreestyleTunnel(api, tunnelCreateOptions)).rejects.toBe(failure);
  });
});

// A fake Freestyle SDK client: records every create, exec, file write, and
// delete so the driver's guest-facing behavior can be asserted without a
// platform. `probeExit` is what the edge readiness probe returns.
function fakeFreestyle(input: { readonly probeExit: number }) {
  const creates: unknown[] = [];
  const resizes: unknown[] = [];
  const execs: string[] = [];
  const writes: Array<{ path: string; content: string }> = [];
  const deletes: string[] = [];
  const vm = {
    exec: async ({ command }: { command: string }) => {
      execs.push(command);
      const statusCode = command.includes("/api/coderouter/vm-usage/self") ? input.probeExit : 0;
      return { statusCode, stdout: "", stderr: statusCode === 0 ? "" : "probe failed" };
    },
    fs: {
      writeTextFile: async (path: string, content: string) => {
        writes.push({ path, content });
      },
    },
    delete: async () => {
      deletes.push(VM_ID);
    },
    data: async () => ({ publicIpv6: "2602:f75c:0:1::2a" }),
    // Every VM boots at its snapshot's resources; create grows it to the plan
    // machine before bootstrap (see growToRequestedSize).
    resize: async (options: unknown) => {
      resizes.push(options);
    },
  };
  const client = {
    vms: {
      create: async (options: unknown) => {
        creates.push(options);
        return { vm, vmId: VM_ID, data: { publicIpv6: "2602:f75c:0:1::2a", vpcs: [] } };
      },
      get: async () => ({ resources: { cpu: 2, memory: 4096, storage: 16384 } }),
      ref: () => vm,
    },
  } as unknown as Freestyle;
  return { client, creates, resizes, execs, writes, deletes };
}

function providerWith(fake: ReturnType<typeof fakeFreestyle>): FreestyleProvider {
  return new FreestyleProvider({
    client: () => fake.client,
    resolveDaemonSource: async () => ({
      url: "https://files.cmux.com/cmux-tui/abc/cmux-tui-linux-x64",
      sha256: "0".repeat(64),
      commit: "abc",
      builtAt: null,
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

  test("openAttach refuses and names cmux-remote", async () => {
    const provider = new FreestyleProvider();
    await expect(provider.openAttach(VM_ID)).rejects.toThrow(ProviderError);
    await expect(provider.openAttach(VM_ID)).rejects.toThrow("cmux-remote");
  });

  test("openSSH refuses as a managed transport even though provider SSH exists", async () => {
    const provider = new FreestyleProvider();
    try {
      await provider.openSSH(VM_ID);
      throw new Error("openSSH unexpectedly resolved");
    } catch (error) {
      expect(error).toBeInstanceOf(ProviderError);
      expect(String(error)).toContain("unmanaged");
      expect(String(error)).toContain("cmux-remote");
    }
  });

  test("revokeSSHIdentity is a no-op, so destroy/cleanup paths stay safe", async () => {
    const provider = new FreestyleProvider();
    await expect(provider.revokeSSHIdentity("identity-1")).resolves.toBeUndefined();
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

  test("network firewall: one members-reach-each-other rule, nothing else", () => {
    // No port/protocol matcher: members reach each other on ALL ports. The
    // same rule is re-created by the reuse-path heal if deleted out of band.
    expect(FREESTYLE_NETWORK_FIREWALL_RULES).toEqual([
      { action: "allow", source: {}, destination: {} },
    ]);
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

  test("cmux-remote route without a private network fails closed", () => {
    expect(() => freestyleCmuxRemoteRoute({ publicIpv6: "2602:f75c:0:1::2a" }, VM_ID)).toThrow(
      "not attached to a private network",
    );
    // The deprecated `networks` alias still resolves for older responses.
    expect(
      freestyleCmuxRemoteRoute(
        { networks: [{ ipv6: "fd7a:115c:a1e0::b" }] },
        VM_ID,
      ),
    ).toBe("ws://[fd7a:115c:a1e0::b]:1337/v1/link");
    expect(() => freestyleCmuxRemoteRoute({ publicIpv6: null }, VM_ID)).toThrow("private network");
    expect(() => freestyleCmuxRemoteRoute({ publicIpv6: "  " }, VM_ID)).toThrow("private network");
  });

  test("an explicit empty canonical vpcs list does not use stale legacy metadata", () => {
    expect(() => freestyleCmuxRemoteRoute(
      {
        publicIpv6: "2602:f75c:0:1::2a",
        vpcs: [],
        networks: [{ ipv6: "fd7a:115c:a1e0::b" }],
      },
      VM_ID,
    )).toThrow("not attached to a private network");
  });

  test("daemon health requires a v6-table listener; start installs the dual-stack override", () => {
    // 0x0539 = 1337; a 0.0.0.0-bound daemon appears only in /proc/net/tcp and
    // cannot accept a private IPv6 connection, so it must be restarted.
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
    const source = { url: "https://files.cmux.com/x", sha256: "f".repeat(64), commit: "abc", builtAt: null };
    const check = freestylePinCheckCommand(source);
    expect(check).toContain("if [ -s /etc/cmux/cmux-tui-pin ]; then");
    expect(check).toContain("cut -d' ' -f1 /etc/cmux/cmux-tui-pin");
    expect(check).toContain(`else ${cmuxTuiPinCheckCommand(source)}; fi`);
  });

  test("model-plane env renders the exact file agent-config.sh persists", () => {
    expect(
      renderFreestyleModelPlaneEnvFile({
        OPENAI_BASE_URL: "https://cmux.example/v1",
        OPENAI_API_KEY: "crt_secret'quote",
        CMUX_CODEROUTER_URL: "https://cmux.example",
      }),
    ).toBe(
      [
        "# generated by cmux from machine boot env; managed, do not edit",
        "export OPENAI_BASE_URL='https://cmux.example/v1'",
        `export OPENAI_API_KEY='crt_secret'\\''quote'`,
        "export CMUX_CODEROUTER_URL='https://cmux.example'",
        "export ANTHROPIC_BASE_URL='https://cmux.example'",
        `export ANTHROPIC_AUTH_TOKEN='crt_secret'\\''quote'`,
        `export ANTHROPIC_API_KEY='crt_secret'\\''quote'`,
        "",
      ].join("\n"),
    );
    expect(renderFreestyleModelPlaneEnvFile({})).toBeNull();
    expect(renderFreestyleModelPlaneEnvFile({ OPENAI_API_KEY: "crt_x" })).toBeNull();
  });


  test("guest payloads never carry a route token", () => {
    expect(() => assertNoRouteTokenInGuestPayload(["echo crt_abc"], "exec")).toThrow(ProviderError);
    expect(() => assertNoRouteTokenInGuestPayload(["cmux-vm-edge-placeholder", "crtnot"], "exec")).not.toThrow();
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

  test("a lost create response is recovered by slug without rotating a live key", async () => {
    const key = "client-public-key";
    const options = {
      slug: "cmux-wg-recovery",
      displayName: "cmux computer",
      clientPublicKey: key,
      networkId: "vpc-dev",
    };
    const existing = {
      id: "tun-recovered",
      tunnelId: "tun-recovered",
      slug: options.slug,
      clientConfig: "[Interface]\\nPrivateKey = \\n[Peer]\\n",
      clientPublicKey: key,
      serverPublicKey: "server-key",
      endpointHost: "vpn.example.invalid",
      endpointPort: 51820,
      routes: ["10.0.0.0/8"],
      attachments: [],
      clientAddressV4: "100.64.0.1",
      clientAddressV6: "fd7a:7570:6c6b::1",
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    let getCalls = 0;
    let attachCalls = 0;
    const recovered = await recoverFreestyleTunnelAfterConflict(
      {
        get: async () => {
          getCalls += 1;
          return existing;
        },
        attachVpc: async () => {
          attachCalls += 1;
          return { ...existing, attachments: [{
            vpcId: options.networkId,
            ipv4: "10.16.170.3",
            ipv6: "fd98:deb9:4c94::3",
            address: "10.16.170.3",
            vpcCidr: "10.16.170.0/24",
            allowedIps: ["10.16.170.0/24"],
            createdAt: new Date().toISOString(),
          }] };
        },
      },
      options,
      key,
    );
    expect(getCalls).toBe(1);
    expect(attachCalls).toBe(1);
    expect(recovered.id).toBe("tun-recovered");
    expect(recovered.addressV4).toBe("10.16.170.3");
  });

  test("recovery refuses a slug collision with a different client key", async () => {
    await expect(
      recoverFreestyleTunnelAfterConflict(
        {
          get: async () => ({
            id: "tun-other",
            tunnelId: "tun-other",
            clientConfig: "[Interface]\\n[Peer]\\n",
            clientPublicKey: "different-key",
            serverPublicKey: "server-key",
            endpointPort: 51820,
            routes: [],
            attachments: [],
            clientAddressV4: "100.64.0.2",
            clientAddressV6: "fd7a:7570:6c6b::2",
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
          }),
          attachVpc: async () => {
            throw new Error("must not attach on key mismatch");
          },
        },
        {
          slug: "cmux-wg-collision",
          displayName: "cmux computer",
          clientPublicKey: "expected-key",
          networkId: "vpc-dev",
        },
        "expected-key",
      ),
    ).rejects.toThrow("different client key");
  });
});

describe("FreestyleProvider create with edge rules", () => {
  test("fails closed when create has no private network", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    await expect(providerWith(fake).create({ image: "sh-devbox" })).rejects.toThrow(
      "create requires a private network",
    );
    expect(fake.creates).toHaveLength(0);
  });

  test("fails closed when restore has no private network", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    await expect(providerWith(fake).restore("snap-1")).rejects.toThrow(
      "restore requires a private network",
    );
    expect(fake.creates).toHaveLength(0);
  });

  test("creates persistent machines with idle pausing disabled", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    await providerWith(fake).create({ image: "sh-devbox", network: { id: "vpc_1" } });

    expect(fake.creates[0]).toMatchObject({
      // Cloud machines keep their durable box available until the user
      // explicitly pauses or destroys it. The explicit -1 also overrides a
      // provider/account default that would otherwise idle-pause the VM.
      idleTimeoutSeconds: -1,
    });
  });

  test("passes the rule inline, writes nothing into the guest, and returns the machine", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    const handle = await providerWith(fake).create({
      image: "sh-devbox",
      edgeRules: [EDGE_RULE],
      network: { id: "vpc_1" },
    });
    expect(handle.providerVmId).toBe(VM_ID);
    expect(fake.creates).toHaveLength(1);
    expect(fake.creates[0]).toMatchObject({
      snapshotId: "sh-devbox",
      firewall: { rules: freestyleFirewallRules() },
      vpcs: [{ vpcId: "vpc_1", ipv4: true, ipv6: true }],
      tls: { rules: freestyleEdgeRules([EDGE_RULE]) },
    });
    // The token reaches the platform create call and nothing else.
    expect(JSON.stringify(fake.execs)).not.toContain("crt_");
    expect(JSON.stringify(fake.writes)).not.toContain("crt_");
    expect(fake.writes).toEqual([]); // the model-plane env is baked, nothing is written into the guest
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
      firewall: { rules: freestyleFirewallRules() },
      vpcs: [{ vpcId: "vpc_1", ipv4: true, ipv6: true }],
      tls: { rules: freestyleEdgeRules([EDGE_RULE]) },
    });
    expect(handle.providerMetadata).toEqual({ networkId: "vpc_1" });
    expect(JSON.stringify(fake.writes)).not.toContain("crt_");
  });

  test("omits the tls block and the probe when no rules are given", async () => {
    const fake = fakeFreestyle({ probeExit: 1 });
    await providerWith(fake).create({ image: "sh-devbox", network: { id: "vpc_1" } });
    expect(fake.creates[0]).not.toHaveProperty("tls");
    expect(fake.execs.some((command) => command.includes("/api/coderouter/vm-usage/self"))).toBe(false);
    expect(fake.writes).toEqual([]);
  });

  test("grows a 4 GB image to the documented 32 GB starting disk", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    await providerWith(fake).create({
      image: "sh-devbox-4gb",
      network: { id: "vpc_1" },
      imageSize: { name: "sm", cpu: 1, memoryMb: 4096, storageMb: 16384 },
    });

    expect(fake.resizes).toEqual([{ storage: 32768 }]);
  });



  test("restore passes the rule inline and writes nothing into the guest", async () => {
    const ok = fakeFreestyle({ probeExit: 0 });
    const restored = await providerWith(ok).restore("snap-1", {
      edgeRules: [EDGE_RULE],
      network: { id: "vpc_1" },
    });
    expect(restored.image).toBe("snap-1");
    expect(ok.creates[0]).toMatchObject({
      snapshotId: "snap-1",
      idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
      firewall: { rules: freestyleFirewallRules() },
      vpcs: [{ vpcId: "vpc_1", ipv4: true, ipv6: true }],
      tls: { rules: freestyleEdgeRules([EDGE_RULE]) },
    });
    expect(ok.writes).toEqual([]);
    expect(JSON.stringify(ok.writes)).not.toContain("crt_");
    expect(ok.deletes).toEqual([]);
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
        builtAt: null,
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
  test("the default plan machine is 2 vCPU / 8 GB / 32 GB, vCPUs following memory", () => {
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
      { cpu: 5, memory: 20480, storage: 32768 },
      { cpu: 5, memory: 20480, storage: 32768 },
    )).toBeNull();
    expect(freestyleResizeRequest(
      { cpu: 8, memory: 32768, storage: 262144 },
      { cpu: 5, memory: 20480, storage: 32768 },
    )).toBeNull();
    expect(freestyleResizeRequest(
      { cpu: 5, memory: 20480, storage: 16384 },
      { cpu: 5, memory: 20480, storage: 32768 },
    )).toEqual({ storage: 32768 });
  });
});

// The desktop and forwarded ports travel the daemon's private path: the URL
// is the machine's VPC address over the owner's tunnel, nothing is minted at
// the platform and nothing public is opened. noVNC on 6901 has no auth of
// its own, so a machine outside a private network gets no URL at all.
describe("Freestyle openCmuxRemote: the trusted-listener heal", () => {
  const PRIVATE = { publicIpv6: "2602:f75c:0:1::2a", vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }] };
  const SOURCE_OK = { url: "https://files.cmux.com/cmux-tui/abc/cmux-tui-linux-x64", sha256: "0".repeat(64), commit: "abc", builtAt: null };

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
