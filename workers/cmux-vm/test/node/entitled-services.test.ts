import { Effect, Layer } from "effect";
import { expect, it } from "vitest";
import type { Actor, Principal } from "../../src/domain/principal.ts";
import type { TenantId } from "../../src/lib/ids.ts";
import { tenantPolicyLayer, type PolicyConfig } from "../../src/policy.ts";
import { Entitlements, entitlementsFromPolicyLayer } from "../../src/proofs/tenant-may-create.ts";

// CMUX_VM_ENTITLED_SERVICE_IDS: in production, a request made with a listed service key is entitled for the team it
// acts for (cmux-platform decided that team's plan), without the team being in MANAFLOW_TEAM_TENANT_IDS.

const principal = (tenantId: string, actor: Actor): Principal => ({
  tenantId: tenantId as TenantId,
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
const config = { entitledServiceIds: ["cloud-platform-production"], manaflowTenantIds: ["team-listed"] };

it("entitles a listed service's request for any team it acts for in production", async () => {
  expect(await mayCreate(config, principal("member-personal-team", platform))).toBe(true);
});

it("refuses an unlisted service, a session and an API key for an unlisted production team", async () => {
  expect(await mayCreate(config, principal("member-personal-team", { kind: "service", serviceId: "cloud-driver" }))).toBe(false);
  expect(await mayCreate(config, principal("member-personal-team", { kind: "session", userId: "user-1" as never }))).toBe(false);
  expect(await mayCreate(config, principal("member-personal-team", { kind: "api_key", keyId: "key-1" as never }))).toBe(false);
});

it("keeps the manaflow-team flag and dev/test rules unchanged", async () => {
  expect(await mayCreate(config, principal("team-listed", { kind: "session", userId: "user-1" as never }))).toBe(true);
  expect(await mayCreate({}, principal("member-personal-team", platform))).toBe(false);
  expect(await mayCreate({}, principal("anyone", { kind: "session", userId: "user-1" as never }), "staging")).toBe(true);
});
