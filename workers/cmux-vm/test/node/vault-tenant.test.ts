import { describe, expect, it } from "vitest";
import type { Actor, Principal } from "../../src/domain/principal.ts";
import { newApiKeyId, TenantId } from "../../src/lib/ids.ts";
import { vaultTenantMetadata } from "../../src/upstream/vault-tenant.ts";

const TEAM = "0b6f3a52-6c1e-4f43-9a1e-2d7c5e8f9a10";
const principal = (tenantId: string, actor: Actor): Principal => ({
  tenantId: TenantId.make(tenantId),
  actor,
  scopes: new Set(),
  resourceAllowlist: null,
  credentialExpiresAt: null,
});
const service = (serviceId: string) => principal(TEAM, { kind: "service", serviceId });

describe("vaultTenantMetadata", () => {
  it("names only the key of the platform environment that made the VM", () => {
    expect(vaultTenantMetadata("production", service("cloud-platform-production"))).toEqual(["cmux_vt", TEAM]);
    expect(vaultTenantMetadata("staging", service("cloud-platform-staging"))).toEqual(["cmux_vt_stg", TEAM]);
    expect(vaultTenantMetadata("staging", service("cloud-platform-dev"))).toEqual(["cmux_vt_dev", TEAM]);
    expect(vaultTenantMetadata("production", service("cloud-platform-dev"))).toEqual(["cmux_vt", TEAM]);
    expect(vaultTenantMetadata("staging", principal(TEAM, { kind: "api_key", keyId: newApiKeyId() }))).toEqual(["cmux_vt_stg", TEAM]);
  });

  it("writes nothing outside staging and production, or for a tenant that is not a Stack team id", () => {
    expect(vaultTenantMetadata("local", service("cloud-platform-dev"))).toBeNull();
    expect(vaultTenantMetadata("preview", service("cloud-platform-staging"))).toBeNull();
    expect(vaultTenantMetadata("production", principal("team_alpha", { kind: "service", serviceId: "cloud-platform-production" }))).toBeNull();
    expect(vaultTenantMetadata("production", principal(TEAM.toUpperCase(), { kind: "service", serviceId: "x" }))).toBeNull();
  });
});
