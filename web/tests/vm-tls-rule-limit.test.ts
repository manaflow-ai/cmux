import { describe, expect, test } from "bun:test";
import { FreestyleApiError, type Freestyle } from "freestyle";

import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { FreestyleTlsRuleLimitRestoreError, reconcileFreestyleEgress } from "../services/vms/drivers/freestyleNetworkPolicy";
import { ProviderError, ProviderTlsRuleLimitError } from "../services/vms/drivers/types";
import { CMUX_REQUIRED_DOMAINS, compileNetworkPolicy, parseNetworkPolicy } from "../services/vms/networkPolicy";
import { VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { freestyleTlsRuleLimit, tlsRuleCapacityAlert } from "../services/observability/providerRuleCapacity";

const ENV = { FREESTYLE_EDGE_ADDRESSES: "2602:f470:1::28", FREESTYLE_GUEST_DNS_RESOLVERS: "8.8.8.8" } as unknown as NodeJS.ProcessEnv;
const vmId = "vm-1";

/** Freestyle's answer when the account already holds its maximum number of TLS rules. */
function tlsRuleLimit(): FreestyleApiError {
  return new FreestyleApiError(409, {
    code: "CONFLICT",
    message: "conflict: TLS rule limit reached (2000); delete unused rules before creating more",
  });
}

type TlsRule = { id: string; domain: string; protocol: string; source: Record<string, unknown>; destination: Record<string, unknown> };

/**
 * A Freestyle account whose TLS rule store is shared with `otherRules` rules
 * this VM does not own, and refuses a create once `cap` rules exist.
 */
function accountAtCap(
  owned: string[],
  otherRules: number,
  cap: number,
  options: { readonly refuse?: (domain: string) => boolean; readonly foreign?: TlsRule[]; readonly failDelete?: (domain: string) => boolean; readonly failListFromCall?: number } = {},
) {
  const tls: TlsRule[] = [
    ...owned.map((domain, index) => ({
      id: `tls-${index}`, domain, protocol: "http", source: { vmId }, destination: { public: true },
    })),
    ...(options.foreign ?? []),
  ];
  const log: string[] = [];
  let next = 0;
  let listCalls = 0;
  const client = {
    firewall: {
      rules: {
        list: async () => ({ rules: [], totalCount: 0 }),
        create: async () => undefined,
        delete: async () => undefined,
      },
    },
    tls: {
      rules: {
        list: async () => {
          listCalls += 1;
          if (options.failListFromCall !== undefined && listCalls >= options.failListFromCall) {
            throw new FreestyleApiError(503, { code: "UNAVAILABLE", message: "list unavailable" });
          }
          return { rules: tls, totalCount: tls.length };
        },
        create: async (rule: { domain: string; source: Record<string, unknown>; destination: Record<string, unknown> }) => {
          if (tls.length + otherRules >= cap || options.refuse?.(rule.domain)) {
            log.push(`tls! ${rule.domain}`);
            throw tlsRuleLimit();
          }
          log.push(`tls+ ${rule.domain}`);
          tls.push({ ...rule, protocol: "http", id: `tls-new-${next++}` });
        },
        delete: async (id: string) => {
          const index = tls.findIndex((rule) => rule.id === id);
          if (options.failDelete?.(tls[index]?.domain ?? "")) {
            log.push(`tls-! ${id}`);
            throw new FreestyleApiError(500, { code: "INTERNAL", message: "delete failed" });
          }
          log.push(`tls- ${id}`);
          tls.splice(index, 1);
        },
      },
    },
  };
  return { client: client as unknown as Freestyle, tls, log };
}

async function failure(run: () => Promise<unknown>): Promise<unknown> {
  try {
    await run();
  } catch (error) {
    return error;
  }
  throw new Error("expected the provider call to fail");
}

// Freestyle caps TLS rules per account (2000), and every cmux machine plus
// every other workload on the account draws from that one pool. At the cap a
// network policy save was answered as a retryable 502 "temporarily
// unavailable", and a domain swap failed even though it would not have grown
// the rule count.
describe("the account-wide Freestyle TLS rule cap", () => {
  test("a domain swap at the cap frees its own surplus rules first and converges", async () => {
    const owned = [...CMUX_REQUIRED_DOMAINS, "old.example.com"];
    const fake = accountAtCap(owned, 2000 - owned.length, 2000);
    const plan = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", domains: ["new.example.com"] }));
    await reconcileFreestyleEgress(fake.client, vmId, plan, ENV);
    expect(fake.tls.map((rule) => rule.domain).sort()).toEqual([...CMUX_REQUIRED_DOMAINS, "new.example.com"].sort());
  });

  test("a policy that needs more rules than the account has is a clear, non-retryable capacity refusal", async () => {
    const fake = accountAtCap([], 2000, 2000);
    const provider = new FreestyleProvider({ client: () => fake.client });
    const plan = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", domains: ["new.example.com"] }));
    const cause = await failure(() => provider.applyNetworkPolicy(vmId, plan));

    const response = await vmWorkflowErrorResponse(
      new VmProviderOperationError({ provider: "freestyle", operation: "applyNetworkPolicy", cause }),
    );
    expect(response).not.toBeNull();
    expect(response!.status).toBe(503);
    expect(response!.headers.get("retry-after")).toBeNull();
    const payload = await response!.json() as Record<string, unknown>;
    expect(payload).toMatchObject({ error: "vm_network_rule_capacity", retryable: false, phase: "network" });
    expect(JSON.stringify(payload)).not.toMatch(/temporarily unavailable|TLS rule limit reached/i);
  });

  test("a swap refused even after freeing its retired rules recreates them and returns the capacity error", async () => {
    const owned = [...CMUX_REQUIRED_DOMAINS, "old.example.com"];
    const fake = accountAtCap(owned, 2000 - owned.length, 2000, { refuse: (domain) => domain === "new.example.com" });
    const plan = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", domains: ["new.example.com"] }));
    const err = await failure(() => reconcileFreestyleEgress(fake.client, vmId, plan, ENV));

    expect(err).toBeInstanceOf(FreestyleTlsRuleLimitRestoreError);
    expect((err as FreestyleTlsRuleLimitRestoreError).restored).toBe(1);
    expect((err as FreestyleTlsRuleLimitRestoreError).unrestored).toEqual([]);
    expect(fake.tls.map((rule) => rule.domain).sort()).toEqual([...owned].sort());
    expect(fake.log).toContain("tls+ old.example.com");

    const provider = new FreestyleProvider({ client: () => accountAtCap(owned, 2000 - owned.length, 2000, { refuse: (domain) => domain === "new.example.com" }).client });
    expect(await failure(() => provider.applyNetworkPolicy(vmId, plan))).toBeInstanceOf(ProviderTlsRuleLimitError);
  });

  test("a partly failed retirement at the cap restores the rules it deleted", async () => {
    const owned = [...CMUX_REQUIRED_DOMAINS, "old-a.example.com", "old-b.example.com"];
    const fake = accountAtCap(owned, 2000 - owned.length, 2000, { failDelete: (domain) => domain === "old-b.example.com" });
    const plan = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", domains: ["new.example.com"] }));
    const err = await failure(() => reconcileFreestyleEgress(fake.client, vmId, plan, ENV));

    expect(err).toBeInstanceOf(FreestyleTlsRuleLimitRestoreError);
    expect((err as FreestyleTlsRuleLimitRestoreError).unrestored).toEqual([]);
    expect(fake.log).toContain("tls+ old-a.example.com");
    expect(fake.tls.map((rule) => rule.domain).sort()).toEqual([...owned].sort());
  });

  test("an unreadable rule list during rollback still recreates the retired rules", async () => {
    const owned = [...CMUX_REQUIRED_DOMAINS, "old.example.com"];
    // Calls 1 and 2 are the first reconcile and the retry; call 3 is the rollback.
    const fake = accountAtCap(owned, 2000 - owned.length, 2000, { refuse: (domain) => domain === "new.example.com", failListFromCall: 3 });
    const plan = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", domains: ["new.example.com"] }));
    const err = await failure(() => reconcileFreestyleEgress(fake.client, vmId, plan, ENV));

    expect(err).toBeInstanceOf(FreestyleTlsRuleLimitRestoreError);
    expect((err as FreestyleTlsRuleLimitRestoreError).restored).toBe(1);
    expect(fake.log).toContain("tls+ old.example.com");
    expect(fake.tls.map((rule) => rule.domain).sort()).toEqual([...owned].sort());
  });

  test("a change that grows the rule count at the cap deletes nothing", async () => {
    const owned = [...CMUX_REQUIRED_DOMAINS, "old.example.com"];
    const fake = accountAtCap(owned, 2000 - owned.length, 2000);
    const plan = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", domains: ["a.example.com", "b.example.com"] }));
    const err = await failure(() => reconcileFreestyleEgress(fake.client, vmId, plan, ENV));

    expect(err).toBeInstanceOf(FreestyleApiError);
    expect(fake.log.filter((line) => line.startsWith("tls-"))).toEqual([]);
    expect(fake.tls.map((rule) => rule.domain).sort()).toEqual([...owned].sort());
  });

  test("freeing rules at the cap never deletes another VM's rules", async () => {
    const foreign: TlsRule = { id: "tls-foreign", domain: "old.example.com", protocol: "http", source: { vmId: "vm-2" }, destination: { public: true } };
    const owned = [...CMUX_REQUIRED_DOMAINS, "old.example.com"];
    const fake = accountAtCap(owned, 2000 - owned.length - 1, 2000, { foreign: [foreign] });
    const plan = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", domains: ["new.example.com"] }));
    await reconcileFreestyleEgress(fake.client, vmId, plan, ENV);

    expect(fake.tls.find((rule) => rule.id === "tls-foreign")).toBeDefined();
    expect(fake.log).not.toContain("tls- tls-foreign");
    expect(fake.tls.filter((rule) => rule.source.vmId === vmId).map((rule) => rule.domain)).toContain("new.example.com");
  });

  test("another 409 CONFLICT stays a provider error, not a capacity refusal", async () => {
    const client = {
      firewall: { rules: { list: async () => ({ rules: [], totalCount: 0 }), create: async () => undefined, delete: async () => undefined } },
      tls: {
        rules: {
          list: async () => ({ rules: [], totalCount: 0 }),
          create: async () => { throw new FreestyleApiError(409, { code: "CONFLICT", message: "conflict: domain already claimed" }); },
          delete: async () => undefined,
        },
      },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    const plan = compileNetworkPolicy(parseNetworkPolicy({ mode: "allowlist", domains: ["new.example.com"] }));
    const cause = await failure(() => provider.applyNetworkPolicy(vmId, plan));
    expect(cause).toBeInstanceOf(ProviderError);
    expect(cause).not.toBeInstanceOf(ProviderTlsRuleLimitError);

    const sameTextOtherCode = new FreestyleApiError(409, { code: "RATE_LIMITED", message: "TLS rule limit reached (2000)" });
    const otherClient = {
      ...client,
      tls: { rules: { ...(client as unknown as { tls: { rules: object } }).tls.rules, create: async () => { throw sameTextOtherCode; } } },
    } as unknown as Freestyle;
    const other = await failure(() => new FreestyleProvider({ client: () => otherClient }).applyNetworkPolicy(vmId, plan));
    expect(other).not.toBeInstanceOf(ProviderTlsRuleLimitError);
  });

  test("FREESTYLE_TLS_RULE_LIMIT accepts only a positive whole number", () => {
    expect(freestyleTlsRuleLimit({})).toBe(2000);
    expect(freestyleTlsRuleLimit({ FREESTYLE_TLS_RULE_LIMIT: "5000" })).toBe(5000);
    for (const value of ["2,000", "2000abc", "-5", "0", "1e3", "12.5"]) {
      expect(freestyleTlsRuleLimit({ FREESTYLE_TLS_RULE_LIMIT: value })).toBe(2000);
    }
  });

  test("the operator alert is a warning near the cap and critical at it", () => {
    expect(tlsRuleCapacityAlert({ provider: "freestyle", count: 100, limit: 2000 })).toBeNull();
    expect(tlsRuleCapacityAlert({ provider: "freestyle", count: 1700, limit: 2000 })).toMatchObject({
      key: "provider-tls-rule-capacity",
      severity: "warning",
    });
    const critical = tlsRuleCapacityAlert({ provider: "freestyle", count: 2170, limit: 2000 });
    expect(critical).toMatchObject({ key: "provider-tls-rule-capacity", severity: "critical" });
    expect(critical!.body).toContain("2170");
  });
});
