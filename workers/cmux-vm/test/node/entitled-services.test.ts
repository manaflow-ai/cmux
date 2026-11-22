import { Effect, Layer } from "effect";
import { expect, it } from "vitest";
import type { Actor, Principal } from "../../src/domain/principal.ts";
import { ApiKeyId, TenantId, UserId } from "../../src/lib/ids.ts";
import { tenantPolicyLayer, type PolicyConfig } from "../../src/policy.ts";
import { Entitlements, entitlementsFromPolicyLayer } from "../../src/proofs/tenant-may-create.ts";

// CMUX_VM_ENTITLED_SERVICE_IDS: in production, a request made with a listed service key is entitled for the team it
// acts for (cmux-platform decided that team's plan), without the team being in MANAFLOW_TEAM_TENANT_IDS.

const principal = (tenantId: string, actor: Actor): Principal => ({
  tenantId: TenantId.make(tenantId),
  actor,
  scopes: new Set(),
  resourceAllowlist: null,
  credentialExpiresAt: null,
});

const mayCreate = (config: Omit<PolicyConfig, "environment">, caller: Principal, environment: PolicyConfig["environment"] = "production") =>
  Effect.runPromise(
    Effect.flatMap(Entitlements, (entitlements) => entitlements.mayCreate(caller, "vm")).pipe(
      Effect.provide(entitlementsFromPolicyLayer.pipe(Layer.provide(tenantPolicyLayer({ environment, ...config })))),
    ),
  );

const platform: Actor = { kind: "service", serviceId: "cloud-platform-production" };
const config = { entitledServiceIds: ["cloud-platform-production"], manaflowTenantIds: ["team_listed"] };

it("entitles a listed service's request for any team it acts for in production", async () => {
  expect(await mayCreate(config, principal("team_member", platform))).toBe(true);
});

it("refuses an unlisted service, a session and an API key for an unlisted production team", async () => {
  expect(await mayCreate(config, principal("team_member", { kind: "service", serviceId: "cloud-driver" }))).toBe(false);
  expect(await mayCreate(config, principal("team_member", { kind: "session", userId: UserId.make("user_ada") }))).toBe(false);
  expect(await mayCreate(config, principal("team_member", { kind: "api_key", keyId: ApiKeyId.make("vmk_" + "a".repeat(26)) }))).toBe(false);
});

it("keeps the manaflow-team flag and dev/test rules unchanged", async () => {
  expect(await mayCreate(config, principal("team_listed", { kind: "session", userId: UserId.make("user_ada") }))).toBe(true);
  expect(await mayCreate({}, principal("team_member", platform))).toBe(false);
  expect(await mayCreate({}, principal("team_anyone", { kind: "session", userId: UserId.make("user_ada") }), "staging")).toBe(true);
});
