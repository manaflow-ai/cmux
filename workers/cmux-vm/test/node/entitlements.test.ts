/**
 * The manaflow-team flag (cx-b4h.16): during the internal phase, production tenants listed in
 * MANAFLOW_TEAM_TENANT_IDS may create VMs without billing. Unlike dev/test tenants they are product
 * machines: no 300 s idle cap (Cloud Chief VMs pause through their own wake/idle logic).
 */
import { Effect, Layer } from "effect";
import { describe, expect, it } from "vitest";
import { TenantId } from "../../src/lib/ids.ts";
import { parseTenantList, resolveIdleTimeout, tenantPolicyLayer, makeTenantPolicy } from "../../src/policy.ts";
import { Entitlements, entitlementsFromPolicyLayer } from "../../src/proofs/tenant-may-create.ts";

const MANAFLOW = TenantId.make("d13acd51-c77d-438a-9610-5369455e2a2f");
const DEV_TEST = TenantId.make("cmux-vm-smoke-service");
const CUSTOMER = TenantId.make("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0");

const config = { environment: "production" as const, devTestTenantIds: [DEV_TEST], manaflowTenantIds: [MANAFLOW] };

const mayCreate = (tenant: TenantId) =>
  Effect.runPromise(
    Effect.flatMap(Entitlements, (e) => e.mayCreate(tenant, "vm")).pipe(
      Effect.provide(entitlementsFromPolicyLayer.pipe(Layer.provide(tenantPolicyLayer(config)))),
    ),
  );

describe("manaflow-team flag in production", () => {
  it("entitles a listed manaflow team and a dev/test tenant, and refuses every other team", async () => {
    expect(await mayCreate(MANAFLOW)).toBe(true);
    expect(await mayCreate(DEV_TEST)).toBe(true);
    expect(await mayCreate(CUSTOMER)).toBe(false);
  });

  it("keeps a manaflow team a product tenant: no dev/test idle cap, default never pause", () => {
    const policy = makeTenantPolicy(config);
    expect(policy.isDevTest(MANAFLOW)).toBe(false);
    expect(policy.isManaflowTeam(MANAFLOW)).toBe(true);
    expect(resolveIdleTimeout(policy, MANAFLOW, undefined)).toEqual({ ok: true, seconds: -1 });
    expect(resolveIdleTimeout(policy, MANAFLOW, 3600)).toEqual({ ok: true, seconds: 3600 });
  });

  it("is off without the list", async () => {
    const policy = makeTenantPolicy({ environment: "production" });
    expect(policy.isManaflowTeam(MANAFLOW)).toBe(false);
  });

  it("parses the var like DEV_TEST_TENANT_IDS (comma or space separated)", () => {
    expect(parseTenantList(" a, b c ")).toEqual(["a", "b", "c"]);
  });
});
