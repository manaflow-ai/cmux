import { Effect, Layer } from "effect";
import { afterEach, expect, it } from "vitest";
import { LimitsUnavailable, memoryLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

// staging 2026-11-27 (ask-6b8661d57a): a create whose ledger refused its intent answered 503, so the platform retried
// it until create_overdue. A refusal that holds for the key is a final, named 409; a lease that lapsed stays a 503.
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
afterEach(async () => { await current?.dispose(); current = undefined; });

const refusing = async (reason: string) => {
  const base = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
  return Layer.succeed(TenantLimits, { ...base, advance: (tenant, key, progress) =>
    progress.phase === "creating" ? Effect.fail(new LimitsUnavailable({ cause: new Error(reason) })) : base.advance(tenant, key, progress) });
};
const create = (t: Harness, key: string) => t.request("/v1/vms", { ...bearer(key), "idempotency-key": "refused-create" }, { method: "POST", body: { displayName: "agent", labels: { role: "team-vm" } } });

it("answers a ledger refusal that holds for the key as a final 409 that names it, and sends no create", async () => {
  current = await makeHarness({ limits: await refusing("allocation intent changed") });
  const key = await current.addKey("team_alpha", ["vm:write"]);
  const answer = await create(current, key);
  expect(answer.status).toBe(409);
  expect(await answer.json()).toMatchObject({ code: "creation.intent_refused", message: expect.stringContaining("allocation intent changed") });
  expect(current.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(0);
});

it("keeps a lapsed claim retryable: 503", async () => {
  current = await makeHarness({ limits: await refusing("idempotency claim expired") });
  const key = await current.addKey("team_alpha", ["vm:write"]);
  expect((await create(current, key)).status).toBe(503);
});
