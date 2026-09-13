import { expect, test } from "bun:test";
import { makeVmResourceUsageHandler } from "../services/vms/resourceUsageIngest";
import { VM_RESOURCE_USAGE_KEY } from "../services/vms/resourceUsage";
import { requireVmPrincipal } from "../services/vms/vmPrincipal";
import type { VmPrincipalRow } from "../services/vms/vmPrincipalContract";

const vm: VmPrincipalRow = { id: "self", providerVmId: "provider-self", provider: "freestyle", userId: "owner",
  billingTeamId: "team", billingPlanId: "pro", displayName: null, slug: null, imageId: "image", imageVersion: null,
  status: "running", createdAt: new Date(0), providerMetadata: { networkId: "keep" } };
function harness(metadata = vm.providerMetadata, failStore = false) {
  const writes: unknown[] = [];
  const handler = makeVmResourceUsageHandler({
    authenticate: (request) => requireVmPrincipal(request, {
      authenticate: async (token) => token === "valid" ? { teamId: "team", stackUserId: "owner", vmId: "self" } : null,
      loadVm: async () => ({ ...vm, providerMetadata: metadata }),
    }),
    now: () => 100000,
    accept: async (machine, usage, receivedAt) => {
      if (failStore) throw new Error("DB unavailable");
      writes.push({ id: machine.id, usage, receivedAt });
    },
  });
  return { handler, writes };
}
function request(body: unknown, token = "valid", id = "self") {
  return new Request("https://cmux.test/api/vm/resource-usage/self", { method: "POST",
    headers: { "x-coderouter-route-token": token, "x-cmux-vm-id": id, "content-type": "application/json" },
    body: JSON.stringify(body) });
}
test("edge-authenticated report writes only the caller's gauges and server timestamp", async () => {
  const { handler, writes } = harness();
  expect((await handler(request({ cpuPercent: 20, memoryUsedMb: 1024, diskUsedMb: 4096, vmId: "other", receivedAt: 1 }))).status).toBe(204);
  expect(writes).toEqual([{ id: "self", usage: { cpuPercent: 20, memoryUsedMb: 1024, diskUsedMb: 4096 }, receivedAt: 100000 }]);
});
test.each([["bad", "self"], ["valid", "other"]])("rejects absent/forged guest identity", async ([token, id]) => {
  const { handler, writes } = harness();
  expect((await handler(request({ cpuPercent: 50 }, token, id))).status).toBe(401);
  expect(writes).toEqual([]);
});
test.each([{ cpuPercent: 101 }, { memoryUsedMb: -1 }, {}, { diskUsedMb: "3" }])("rejects invalid report %j", async (body) => {
  const { handler, writes } = harness();
  expect((await handler(request(body))).status).toBe(400);
  expect(writes).toEqual([]);
});
test("rejects oversized streamed bodies", async () => {
  const { handler, writes } = harness();
  expect((await handler(request({ padding: "x".repeat(2000), cpuPercent: 1 }))).status).toBe(413);
  expect(writes).toEqual([]);
});
test("delegates throttle eligibility to storage rather than the auth snapshot", async () => {
  const { handler, writes } = harness({ [VM_RESOURCE_USAGE_KEY]: { receivedAt: 99000 } });
  expect((await handler(request({ cpuPercent: 0 }))).status).toBe(204);
  expect(writes).toHaveLength(1);
});
test("a failed durable write is retryable and never acknowledged", async () => {
  const { handler } = harness({}, true);
  expect((await handler(request({ cpuPercent: 0 }))).status).toBe(503);
});
