import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, test } from "bun:test";
import {
  FREESTYLE_NETWORK_FIREWALL_RULES,
  FreestyleProvider,
  freestyleCmuxRemoteRoute,
  freestyleNetworkAddressMetadata,
  freestyleDaemonHealthyCommand,
  freestyleFirewallRules,
  freestyleResizeRequest,
  freestyleStartDaemonCommand,
  freestyleTargetResources,
  mapFreestyleState,
  normalizeFreestyleExecTimeout,
  renderFreestyleModelPlaneEnvFile,
  freestylePinCheckCommand,
} from "../services/vms/drivers/freestyle";
import { cmuxTuiPinCheckCommand } from "../services/vms/drivers/cmuxTuiDaemon";
import { ProviderError } from "../services/vms/drivers/types";

const VM_ID = "vm-d05087e5773e4a978036fc806b0cd759";

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

  test("openSSH refuses: the public platform has no SSH gateway", async () => {
    const provider = new FreestyleProvider();
    await expect(provider.openSSH(VM_ID)).rejects.toThrow(ProviderError);
    await expect(provider.openSSH(VM_ID)).rejects.toThrow("cmux-remote");
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
        "",
      ].join("\n"),
    );
    expect(renderFreestyleModelPlaneEnvFile({})).toBeNull();
    expect(renderFreestyleModelPlaneEnvFile({ OPENAI_API_KEY: "crt_x" })).toBeNull();
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

const driverSource = readFileSync(
  path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"),
  "utf8",
);

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
