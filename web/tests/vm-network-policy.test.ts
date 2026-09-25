import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";

import {
  CMUX_REQUIRED_DOMAINS,
  NetworkPolicyValidationError,
  canonicalCidr,
  compileNetworkPolicy,
  parseNetworkPolicy,
  storedNetworkPolicy,
} from "../services/vms/networkPolicy";
import {
  EGRESS_RULE_DESCRIPTION,
  egressDestinations,
  reconcileFreestyleEgress,
} from "../services/vms/drivers/freestyleNetworkPolicy";
import { freestyleFirewallRules } from "../services/vms/drivers/freestyle";

const ENV = { FREESTYLE_EDGE_ADDRESSES: "2602:f470:1::28", FREESTYLE_GUEST_DNS_RESOLVERS: "8.8.8.8" } as unknown as NodeJS.ProcessEnv;

describe("network policy parsing", () => {
  test("canonicalizes addresses and ranges", () => {
    expect(canonicalCidr("1.2.3.4")).toBe("1.2.3.4/32");
    expect(canonicalCidr("10.1.2.3/8")).toBe("10.0.0.0/8");
    expect(canonicalCidr("2606:4700:4700:0:0:0:0:1111")).toBe("2606:4700:4700::1111/128");
    expect(canonicalCidr("2001:db8::1/32")).toBe("2001:db8::/32");
    expect(canonicalCidr("::/0")).toBe("::/0");
    expect(() => canonicalCidr("300.1.1.1")).toThrow(NetworkPolicyValidationError);
    expect(() => canonicalCidr("1.2.3.4/33")).toThrow(NetworkPolicyValidationError);
    expect(() => canonicalCidr("example.com")).toThrow(NetworkPolicyValidationError);
  });

  test("normalizes domains and rejects wildcards with a path", () => {
    const policy = parseNetworkPolicy({ mode: "allowlist", domains: ["HTTPS://API.Example.com/v1", "api.example.com"] });
    expect(policy.domains).toEqual(["api.example.com"]);
    try {
      parseNetworkPolicy({ mode: "allowlist", domains: ["ok.com", "*.example.com"] });
      throw new Error("expected a validation error");
    } catch (err) {
      expect(err).toBeInstanceOf(NetworkPolicyValidationError);
      expect((err as NetworkPolicyValidationError).path).toBe("domains.1");
    }
  });

  test("a port needs a protocol, and unknown presets fail", () => {
    expect(() => parseNetworkPolicy({ mode: "allowlist", ranges: [{ cidr: "1.1.1.1", port: 443 }] })).toThrow("a port needs a protocol");
    expect(() => parseNetworkPolicy({ mode: "allowlist", presets: ["nope"] })).toThrow("unknown preset");
  });

  test("legacy rows are full; corrupt rows fail closed", () => {
    expect(storedNetworkPolicy(null).mode).toBe("full");
    expect(storedNetworkPolicy({ mode: "sideways" }).mode).toBe("none");
  });
});

describe("network policy compilation", () => {
  test("full and 0.0.0.0/0 both open the whole Internet", () => {
    expect(compileNetworkPolicy(parseNetworkPolicy({ mode: "full" })).publicEgress).toBe(true);
    expect(compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", ranges: ["0.0.0.0/0"] })).publicEgress).toBe(true);
  });

  test("none keeps only cmux hosts; allowlist adds presets, domains, ranges, DNS", () => {
    const none = compileNetworkPolicy(parseNetworkPolicy({ mode: "none", domains: ["ignored.com"], ranges: ["1.1.1.1"] }));
    expect(none).toEqual({ publicEgress: false, ranges: [], domains: [...CMUX_REQUIRED_DOMAINS], dns: false });

    const allow = compileNetworkPolicy(parseNetworkPolicy({
      mode: "allowlist",
      presets: ["openrouter"],
      domains: ["example.com", "github.com"],
      ranges: [{ cidr: "1.1.1.1", port: 443, protocol: "tcp" }],
    }));
    expect(allow.domains).toContain("openrouter.ai");
    expect(allow.domains).toContain("example.com");
    expect(allow.domains.filter((domain) => domain === "github.com")).toHaveLength(1);
    expect(allow.dns).toBe(true);

    const destinations = egressDestinations(allow, ENV);
    expect(destinations).toContainEqual({ cidr: "1.1.1.1/32", port: 443, protocol: "tcp" });
    expect(destinations).toContainEqual({ cidr: "8.8.8.8/32", port: 53, protocol: "udp" });
    // The CodeRouter host-alias rules need the edge on 443 in every restricted mode.
    expect(destinations).toContainEqual({ cidr: "2602:f470:1::28/128", port: 443, protocol: "tcp" });
    expect(destinations.some((destination) => destination.public)).toBe(false);
  });

  test("create-time firewall rules follow the plan and keep daemon ingress", () => {
    expect(freestyleFirewallRules({})).toEqual([{ action: "allow", source: {}, destination: { public: true } }]);
    const restricted = freestyleFirewallRules({
      publicDaemonIngress: true,
      networkRules: compileNetworkPolicy(parseNetworkPolicy({ mode: "none" })),
    });
    expect(restricted.some((rule) => rule.destination.public && rule.source.public === undefined)).toBe(false);
    expect(restricted.some((rule) => rule.source.public === true)).toBe(true);
  });
});

type FakeFirewallRule = { id: string; action: "allow"; source: Record<string, unknown>; destination: Record<string, unknown>; description?: string | null };
type FakeTlsRule = { id: string; domain: string; protocol: string; source: Record<string, unknown>; destination: Record<string, unknown>; transform?: unknown[]; managed?: boolean };

function fakeFreestyle(firewall: FakeFirewallRule[], tls: FakeTlsRule[]) {
  const log: string[] = [];
  let next = 0;
  const client = {
    firewall: {
      rules: {
        list: async () => ({ rules: firewall, totalCount: firewall.length }),
        create: async (rule: Omit<FakeFirewallRule, "id">) => {
          log.push(`fw+ ${JSON.stringify(rule.destination)}`);
          firewall.push({ ...rule, id: `fw-new-${next++}` });
        },
        delete: async (id: string) => {
          log.push(`fw- ${id}`);
          firewall.splice(firewall.findIndex((rule) => rule.id === id), 1);
        },
      },
    },
    tls: {
      rules: {
        list: async () => ({ rules: tls, totalCount: tls.length }),
        create: async (rule: Omit<FakeTlsRule, "id" | "protocol">) => {
          log.push(`tls+ ${rule.domain}`);
          tls.push({ ...rule, protocol: "http", id: `tls-new-${next++}` });
        },
        delete: async (id: string) => {
          log.push(`tls- ${id}`);
          tls.splice(tls.findIndex((rule) => rule.id === id), 1);
        },
      },
    },
  };
  return { client: client as unknown as Freestyle, log, firewall, tls };
}

describe("Freestyle egress reconcile", () => {
  const vmId = "vm-1";
  const ingress: FakeFirewallRule = { id: "fw-ingress", action: "allow", source: { public: true }, destination: { vmId, port: 1337, protocol: "tcp" } };
  const legacyPublic: FakeFirewallRule = { id: "fw-legacy", action: "allow", source: { vmId }, destination: { public: true } };
  const coderouter: FakeTlsRule = {
    id: "tls-cr", domain: "coderouter.cmux.internal", protocol: "http", source: { vmId },
    destination: { host: "cmux.com", port: 443 }, transform: [{ headers: { authorization: "***" } }],
  };

  test("tightening grants first, then removes the legacy public rule, and never touches ingress or CodeRouter", async () => {
    const fake = fakeFreestyle([ingress, { ...legacyPublic }], [coderouter]);
    const plan = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", presets: ["openrouter"] }));
    await reconcileFreestyleEgress(fake.client, vmId, plan, ENV);

    const firstDelete = fake.log.findIndex((line) => line.startsWith("fw-") || line.startsWith("tls-"));
    const lastCreate = fake.log.map((line) => line.includes("+")).lastIndexOf(true);
    expect(lastCreate).toBeLessThan(firstDelete);
    expect(fake.log).toContain("fw- fw-legacy");
    expect(fake.firewall.find((rule) => rule.id === "fw-ingress")).toBeDefined();
    expect(fake.tls.find((rule) => rule.id === "tls-cr")).toBeDefined();
    expect(fake.tls.map((rule) => rule.domain)).toContain("openrouter.ai");
    expect(fake.firewall.every((rule) => rule.id === "fw-ingress" || rule.description === EGRESS_RULE_DESCRIPTION)).toBe(true);
  });

  test("reconcile is idempotent and loosening back to full removes steering rules", async () => {
    const fake = fakeFreestyle([ingress], [coderouter]);
    const allow = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", domains: ["example.com"] }));
    await reconcileFreestyleEgress(fake.client, vmId, allow, ENV);
    const before = fake.log.length;
    const again = await reconcileFreestyleEgress(fake.client, vmId, allow, ENV);
    expect(again).toEqual({ firewallCreated: 0, firewallDeleted: 0, tlsCreated: 0, tlsDeleted: 0 });
    expect(fake.log.length).toBe(before);

    await reconcileFreestyleEgress(fake.client, vmId, compileNetworkPolicy(parseNetworkPolicy({ mode: "full" })), ENV);
    expect(fake.tls.map((rule) => rule.id)).toEqual(["tls-cr"]);
    expect(fake.firewall.filter((rule) => rule.destination.public === true)).toHaveLength(1);
  });
});
