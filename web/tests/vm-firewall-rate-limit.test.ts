import { describe, expect, test } from "bun:test";
import { enforceVmFirewallRateLimit } from "../services/vms/firewallRateLimit";

// Firewall mutations go to one provider account shared by every cmux user, so they are throttled per user.
const request = new Request("https://cmux.test/api/vm/firewall", { method: "POST" });
const base = { request, route: "vm.firewall.create", userId: "user-1", ruleId: "rl-fw", isVercel: true };

describe("enforceVmFirewallRateLimit", () => {
  test("a limited user gets 429 vm_rate_limited with Retry-After, keyed by user", async () => {
    const keys: Array<string | undefined> = [];
    const response = await enforceVmFirewallRateLimit({ ...base, check: async (_id, options) => { keys.push(options.rateLimitKey); return { rateLimited: true }; } });
    expect(response?.status).toBe(429);
    expect(response?.headers.get("retry-after")).toBe("60");
    expect(((await response?.json()) as { error: string }).error).toBe("vm_rate_limited");
    expect(keys).toEqual(["vm-firewall:user-1"]);
  });
  test("an allowed request passes", async () => {
    expect(await enforceVmFirewallRateLimit({ ...base, check: async () => ({ rateLimited: false }) })).toBeNull();
  });
  test("an unavailable firewall fails closed (503)", async () => {
    const response = await enforceVmFirewallRateLimit({ ...base, check: async () => { throw new Error("down"); } });
    expect(response?.status).toBe(503);
  });
  test("an unset or removed rule fails open; outside Vercel there is no check", async () => {
    expect(await enforceVmFirewallRateLimit({ ...base, ruleId: "", check: async () => ({ rateLimited: true }) })).toBeNull();
    expect(await enforceVmFirewallRateLimit({ ...base, check: async () => ({ rateLimited: false, error: "not-found" }) })).toBeNull();
    expect(await enforceVmFirewallRateLimit({ ...base, isVercel: false, check: async () => ({ rateLimited: true }) })).toBeNull();
  });
});
