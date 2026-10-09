import { describe, expect, test } from "bun:test";
import { FreestyleApiError, type Freestyle } from "freestyle";

import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { reconcileFreestyleEgress } from "../services/vms/drivers/freestyleNetworkPolicy";
import { CMUX_REQUIRED_DOMAINS, compileNetworkPolicy, parseNetworkPolicy } from "../services/vms/networkPolicy";
import { VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { tlsRuleCapacityAlert } from "../services/observability/providerRuleCapacity";

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
function accountAtCap(owned: string[], otherRules: number, cap: number) {
  const tls: TlsRule[] = owned.map((domain, index) => ({
    id: `tls-${index}`, domain, protocol: "http", source: { vmId }, destination: { public: true },
  }));
  const log: string[] = [];
  let next = 0;
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
        list: async () => ({ rules: tls, totalCount: tls.length }),
        create: async (rule: { domain: string; source: Record<string, unknown>; destination: Record<string, unknown> }) => {
          if (tls.length + otherRules >= cap) {
            log.push(`tls! ${rule.domain}`);
            throw tlsRuleLimit();
          }
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
