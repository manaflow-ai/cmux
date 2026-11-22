/**
 * cmux#35013: a create whose provider receipt does not match the request (before cmux#35012, a never-pause create read
 * back as idle timeout null) failed with 503 and left the provider VM running with no ownership row. The create now
 * deletes the VM it made before it fails.
 */
import { afterEach, expect, it } from "vitest";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness | undefined;
afterEach(async () => { await h?.dispose(); h = undefined; });

/** The provider answers every create, and every later read of that VM, with an idle timeout nobody asked for. */
const mismatchedReceipts = (t: Harness) => {
  const upstream = t.upstream.fetch;
  t.upstream.fetch = async (request) => {
    const response = await upstream(request);
    if (request.method === "POST" && new URL(request.url).pathname === "/v5/vms" && response.ok) {
      const body = await response.json<Record<string, unknown>>();
      for (const vm of t.upstream.vms.values()) vm.idleTimeoutSeconds = 4321;
      return Response.json({ ...body, idleTimeoutSeconds: 4321 });
    }
    return response;
  };
};

it.each([["unkeyed", undefined], ["keyed", "receipt-mismatch"]] as const)("%s create: a mismatched receipt deletes the VM it made and records nothing", async (_kind, key) => {
  h = await makeHarness({ maxVms: 2 });
  const t = h, token = await t.addKey("team_alpha", ["vm:read", "vm:write"]);
  mismatchedReceipts(t);
  const response = await t.request("/v1/vms", { authorization: `Bearer ${token}`, ...(key === undefined ? {} : { "idempotency-key": key }) }, { method: "POST", body: { displayName: "mismatch" } });
  expect(response.status).toBe(503);
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  expect(t.upstream.callsTo("DELETE", /^\/v5\/vms\/[^/]+$/)).toHaveLength(1);
  expect(t.upstream.vms.size).toBe(0);
  expect(t.resources.filter((row) => !t.isDeleted(row.cmuxId))).toHaveLength(0);
});
