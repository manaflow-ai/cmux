import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, setSystemTime, test } from "bun:test";
import type { Freestyle } from "freestyle";
import {
  FREESTYLE_NETWORK_FIREWALL_RULES,
  FreestyleProvider,
  PORT_OPEN_LEASE_TTL_SECONDS,
  assertNoRouteTokenInGuestPayload,
  freestyleCmuxRemoteRoute,
  freestyleNetworkAddressMetadata,
  freestyleRouteAddressesFromMetadata,
  freestyleDaemonHealthyCommand,
  freestyleDesktopHealCommand,
  freestyleEdgeProbeCommand,
  freestyleEdgeRules,
  freestyleFirewallRules,
  freestylePortAddress,
  freestylePortUrls,
  freestyleResizeRequest,
  freestyleStartDaemonCommand,
  freestyleTargetResources,
  mapFreestyleState,
  normalizeFreestyleExecTimeout,
  renderFreestyleModelPlaneEnvFile,
  freestylePinCheckCommand,
} from "../services/vms/drivers/freestyle";
import type { VMProvider } from "../services/vms/drivers/types";
import { cmuxTuiPinCheckCommand } from "../services/vms/drivers/cmuxTuiDaemon";
import { ProviderError, type VmEdgeRule } from "../services/vms/drivers/types";
import { DEVBOX_DESKTOP_NOVNC_PORT } from "../services/vms/images/desktop";

const VM_ID = "vm-d05087e5773e4a978036fc806b0cd759";
const CLOUD_VM_ID = "11111111-2222-4333-8444-555555555555";
const EDGE_RULE: VmEdgeRule = {
  domain: "coderouter.dev",
  headers: { "x-coderouter-route-token": "crt_secret-token", "x-cmux-vm-id": CLOUD_VM_ID },
};
const PLACEHOLDER_ENVS = {
  OPENAI_BASE_URL: "https://coderouter.dev/v1",
  OPENAI_API_KEY: "cmux-vm-edge-placeholder",
  CMUX_CODEROUTER_URL: "https://coderouter.dev",
  ANTHROPIC_BASE_URL: "https://coderouter.dev",
  ANTHROPIC_API_KEY: "cmux-vm-edge-placeholder",
  CMUX_VM_ID: CLOUD_VM_ID,
};

// A fake Freestyle SDK client: records every create, exec, file write, and
// delete so the driver's guest-facing behavior can be asserted without a
// platform. `probeExit` is what the edge readiness probe returns.
function fakeFreestyle(input: { readonly probeExit: number }) {
  const creates: unknown[] = [];
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
    resize: async () => {},
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
  return { client, creates, execs, writes, deletes };
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
    expect(start).toContain("systemctl restart cmux-tui-daemon");
    expect(start).toContain("--remote-ws [::]:1337"); // non-systemd fallback
  });

  test("pin check trusts the pin recorded at bake time, falling back to the live pin on older images", () => {
    const source = { url: "https://files.cmux.com/x", sha256: "f".repeat(64), commit: "abc", builtAt: null };
    const check = freestylePinCheckCommand(source);
    expect(check).toContain("if [ -s /etc/cmux/cmux-tui-pin ]; then");
    expect(check).toContain("cut -d' ' -f1 /etc/cmux/cmux-tui-pin");
    expect(check).toContain(`else ${cmuxTuiPinCheckCommand(source)}; fi`);
  });

  test("model-plane env renders every key into the file agent-config.sh persists", () => {
    expect(
      renderFreestyleModelPlaneEnvFile({
        OPENAI_BASE_URL: "https://cmux.example/v1",
        OPENAI_API_KEY: "place'holder",
        CMUX_CODEROUTER_URL: "https://cmux.example",
        ANTHROPIC_BASE_URL: "https://cmux.example",
        ANTHROPIC_API_KEY: "placeholder",
        CMUX_VM_ID: CLOUD_VM_ID,
        EMPTY: "",
      }),
    ).toBe(
      [
        "# generated by cmux from machine boot env; managed, do not edit",
        "export OPENAI_BASE_URL='https://cmux.example/v1'",
        `export OPENAI_API_KEY='place'\\''holder'`,
        "export CMUX_CODEROUTER_URL='https://cmux.example'",
        "export ANTHROPIC_BASE_URL='https://cmux.example'",
        "export ANTHROPIC_API_KEY='placeholder'",
        `export CMUX_VM_ID='${CLOUD_VM_ID}'`,
        "",
      ].join("\n"),
    );
    expect(renderFreestyleModelPlaneEnvFile({})).toBeNull();
    expect(renderFreestyleModelPlaneEnvFile({ OPENAI_API_KEY: "placeholder" })).toBeNull();
    expect(() => renderFreestyleModelPlaneEnvFile({ OPENAI_BASE_URL: "https://x/v1", "BAD-KEY": "v" })).toThrow(
      ProviderError,
    );
  });

  test("the guest env file never carries a route token", () => {
    expect(() =>
      renderFreestyleModelPlaneEnvFile({
        OPENAI_BASE_URL: "https://cmux.example/v1",
        OPENAI_API_KEY: "crt_secret-token",
      }),
    ).toThrow("route token");
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

  test("edge probe is one bounded guest loop against the rule's host, with no token in it", () => {
    const command = freestyleEdgeProbeCommand("coderouter.dev");
    expect(command).toBe(
      "for i in $(seq 1 30); do curl -fsS -o /dev/null --max-time 5 -H 'authorization: Bearer cmux-vm-edge-placeholder' https://coderouter.dev/api/coderouter/vm-usage/self && exit 0; sleep 2; done; exit 1",
    );
    expect(command).not.toContain("crt_");
    expect(() => freestyleEdgeProbeCommand("bad host")).toThrow(ProviderError);
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
});

describe("FreestyleProvider create with edge rules", () => {
  test("passes the rule inline, writes placeholder env only, probes, and returns the machine", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    const handle = await providerWith(fake).create({
      image: "sh-devbox",
      envs: PLACEHOLDER_ENVS,
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
    expect(JSON.stringify(fake.writes)).not.toContain("crt_");
    expect(fake.writes).toEqual([
      {
        path: "/root/.config/cmux/model-plane.env",
        content: renderFreestyleModelPlaneEnvFile(PLACEHOLDER_ENVS)!,
      },
    ]);
    expect(fake.execs.some((command) => command.includes("https://coderouter.dev/api/coderouter/vm-usage/self"))).toBe(true);
    expect(fake.deletes).toEqual([]);
  });

  test("keeps the inline tls rule when the machine joins a private network", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    const handle = await providerWith(fake).create({
      image: "sh-devbox",
      envs: PLACEHOLDER_ENVS,
      edgeRules: [EDGE_RULE],
      network: { id: "vpc_1" },
    });
    expect(fake.creates[0]).toMatchObject({
      firewall: { rules: freestyleFirewallRules({ publicDaemonIngress: false }) },
      vpcs: [{ vpcId: "vpc_1", ipv4: true, ipv6: true }],
      tls: { rules: freestyleEdgeRules([EDGE_RULE]) },
    });
    expect(handle.providerMetadata).toEqual({ networkId: "vpc_1" });
    expect(JSON.stringify(fake.writes)).not.toContain("crt_");
  });

  test("omits the tls block and the probe when no rules are given", async () => {
    const fake = fakeFreestyle({ probeExit: 1 });
    await providerWith(fake).create({ image: "sh-devbox" });
    expect(fake.creates[0]).not.toHaveProperty("tls");
    expect(fake.execs.some((command) => command.includes("/api/coderouter/vm-usage/self"))).toBe(false);
    expect(fake.writes).toEqual([]);
  });

  test("rolls the machine back when the edge probe never succeeds", async () => {
    const fake = fakeFreestyle({ probeExit: 1 });
    const failure = await providerWith(fake)
      .create({ image: "sh-devbox", envs: PLACEHOLDER_ENVS, edgeRules: [EDGE_RULE] })
      .catch((err: unknown) => err);
    expect(failure).toBeInstanceOf(ProviderError);
    expect((failure as ProviderError).message).toContain("edge rule for coderouter.dev");
    expect((failure as ProviderError).message).toContain("inactive");
    expect(fake.deletes).toEqual([VM_ID]);
  });

  test("refuses to create when an env value is a route token", async () => {
    const fake = fakeFreestyle({ probeExit: 0 });
    await expect(
      providerWith(fake).create({
        image: "sh-devbox",
        envs: { ...PLACEHOLDER_ENVS, OPENAI_API_KEY: "crt_leaked" },
        edgeRules: [EDGE_RULE],
      }),
    ).rejects.toThrow("route token");
    expect(fake.writes).toEqual([]);
    expect(fake.deletes).toEqual([VM_ID]);
  });

  test("restore passes the rule inline, writes the new env, probes, and rolls back on failure", async () => {
    const ok = fakeFreestyle({ probeExit: 0 });
    const restored = await providerWith(ok).restore("snap-1", { envs: PLACEHOLDER_ENVS, edgeRules: [EDGE_RULE] });
    expect(restored.image).toBe("snap-1");
    expect(ok.creates[0]).toMatchObject({ snapshotId: "snap-1", tls: { rules: freestyleEdgeRules([EDGE_RULE]) } });
    expect(ok.writes.map((write) => write.path)).toEqual(["/root/.config/cmux/model-plane.env"]);
    expect(JSON.stringify(ok.writes)).not.toContain("crt_");
    expect(ok.deletes).toEqual([]);

    const bad = fakeFreestyle({ probeExit: 1 });
    await expect(
      providerWith(bad).restore("snap-1", { envs: PLACEHOLDER_ENVS, edgeRules: [EDGE_RULE] }),
    ).rejects.toThrow("inactive");
    expect(bad.deletes).toEqual([VM_ID]);
  });
});

const driverSource = readFileSync(
  path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"),
  "utf8",
);

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
    expect(packageJson.dependencies.freestyle).toBe("0.2.9");
  });
});

describe("Freestyle machine sizing", () => {
  test("the plan machine is 5 vCPU / 20 GB / 200 GB, vCPUs following memory", () => {
    expect(freestyleTargetResources(20480, {})).toEqual({ cpu: 5, memory: 20480, storage: 204800 });
    expect(freestyleTargetResources(8192, {})).toEqual({ cpu: 2, memory: 8192, storage: 204800 });
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
      { cpu: 5, memory: 20480, storage: 204800 },
    )).toEqual({ cpu: 5, memory: 20480, storage: 204800 });
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
