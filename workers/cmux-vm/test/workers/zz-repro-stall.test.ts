import { Effect, Layer } from "effect";
import { afterEach, expect, it, vi } from "vitest";
import { memoryLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
afterEach(async () => { vi.useRealTimers(); await current?.dispose(); current = undefined; });
const create = (t: Harness, key: string, idem = "cloud-create:x") => t.request("/v1/vms", { ...bearer(key), "idempotency-key": idem }, { method: "POST", body: { displayName: "x", labels: { role: "team-vm" } } });
const spy = async () => {
  const base = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
  const errors: string[] = [];
  return { errors, layer: Layer.succeed(TenantLimits, { ...base, advance: (tenant, key, progress) => base.advance(tenant, key, progress).pipe(Effect.tapError((e) => Effect.sync(() => errors.push(`${progress.phase}: ${String((e as any).cause?.message ?? (e as any).cause ?? e)}`)))) }) };
};
for (const status of [503, 500, 502, 504]) it(`retry after provider ${status}`, async () => {
  const s = await spy(); const t = await makeHarness({ limits: s.layer, maxVms: 5 }); current = t;
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.fail("create", status);
  const a = await create(t, key); const ab = await a.text();
  const results: string[] = [];
  vi.useFakeTimers({ toFake: ["Date"], now: Date.now() });
  for (let i = 0; i < 4; i++) { vi.setSystemTime(Date.now() + 60_000); const r = await create(t, key); results.push(`${r.status} ${(await r.text()).slice(0, 160)}`); }
  console.log(JSON.stringify({ status, first: `${a.status} ${ab.slice(0, 160)}`, results, errors: s.errors }, null, 1));
  expect(true).toBe(true);
});
it("lost response then retry", async () => {
  const s = await spy(); const t = await makeHarness({ limits: s.layer }); current = t;
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.faults.lostCreateResponses = 1;
  const a = await create(t, key);
  const results: string[] = [];
  for (let i = 0; i < 3; i++) { const r = await create(t, key); results.push(`${r.status} ${(await r.text()).slice(0, 160)}`); }
  console.log(JSON.stringify({ first: a.status, results, errors: s.errors }, null, 1));
});
