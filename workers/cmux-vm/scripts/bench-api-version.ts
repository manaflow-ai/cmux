/**
 * What `Cmux-Api-Version` costs per request (src/api-version.ts): resolving a
 * pin, an unpinned request, a pin with nothing to translate, and a client one
 * version back whose GET /v1/vms/{vmId} reply is translated. Run:
 * `bun scripts/bench-api-version.ts`. The handler is a constant reply, so the
 * numbers are the wrapper's own cost, not the API's.
 */
import { API_VERSIONS, BASE_DATE, resolvePin, withApiVersion, type ApiVersionTable } from "../src/api-version.ts";

const ONE_BACK: ApiVersionTable = {
  baseDate: BASE_DATE,
  versions: [{ date: "2027-01-01", note: "bench", changes: [{ message: "response:GET /v1/vms/{vmId}", op: "rename", path: "/status", to: "state" }] }],
};

const vm = JSON.stringify({
  id: "vm_01jcmux0000000000000000000", state: "running", image: "cloud-standard", createdAt: "2026-11-24T00:00:00.000Z",
  labels: { lane: "bench", owner: "team_alpha" }, displayName: null, cpu: 4, memoryMiB: 8192, region: "iad", tenantId: "team_alpha",
});
const handler = async () => new Response(vm, { headers: { "content-type": "application/json" } });
const url = "https://vm.test/v1/vms/vm_01jcmux0000000000000000000";

const measure = async (name: string, run: () => unknown | Promise<unknown>, iterations = 200_000) => {
  for (let i = 0; i < 10_000; i += 1) await run();
  const start = performance.now();
  for (let i = 0; i < iterations; i += 1) await run();
  const ns = ((performance.now() - start) * 1e6) / iterations;
  console.log(`${name.padEnd(44)} ${ns.toFixed(0).padStart(7)} ns/op`);
  return ns;
};

const plain = new Request(url);
const pinnedBase = new Request(url, { headers: { "cmux-api-version": BASE_DATE } });
const current = withApiVersion(handler, API_VERSIONS);
const back = withApiVersion(handler, ONE_BACK);

await measure("resolvePin(2026-11-24)", () => resolvePin(BASE_DATE, ONE_BACK), 1_000_000);
const bare = await measure("handler alone (baseline)", () => handler());
const unpinned = await measure("unpinned request", () => current(plain));
const same = await measure("pinned, nothing to translate", () => current(pinnedBase));
const oneBack = await measure("pinned one version back (reply translated)", () => back(pinnedBase), 100_000);
console.log(`\nwrapper cost: unpinned ${(unpinned - bare).toFixed(0)} ns, pinned current ${(same - bare).toFixed(0)} ns, one version back ${((oneBack - bare) / 1000).toFixed(2)} µs`);
