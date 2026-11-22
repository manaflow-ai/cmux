import { expect, it } from "vitest";
import { applyServiceScopeGrants, parseServiceScopeGrants, type ServiceKey } from "../../src/auth/service-keys.ts";

// CMUX_VM_SERVICE_KEY_SCOPE_GRANTS: a plain var that adds only the mesh ACL scopes to named service keys.

const key = (id: string): ServiceKey => ({ id, sha256: "a".repeat(64), scopes: new Set(["mesh:read", "mesh:write"]), labels: { role: "cloud" }, teams: null });

it("parses grants of acl:read and acl:write by service key id", () => {
  const parsed = parseServiceScopeGrants('{"cloud-platform-dev":["acl:read","acl:write"]}');
  expect(parsed.ok).toBe(true);
  expect([...parsed.grants.entries()]).toEqual([["cloud-platform-dev", ["acl:read", "acl:write"]]]);
  expect(parseServiceScopeGrants(undefined)).toEqual({ ok: true, grants: new Map() });
  expect(parseServiceScopeGrants("  ")).toEqual({ ok: true, grants: new Map() });
});

it("refuses every scope but the ACL's, and malformed grants, granting nothing", () => {
  for (const raw of [
    '{"cloud-platform-dev":["admin"]}',
    '{"cloud-platform-dev":["vm:exec"]}',
    '{"cloud-platform-dev":["acl:write","mesh:write"]}',
    '{"cloud-platform-dev":[]}',
    '{"Bad Id":["acl:read"]}',
    '["acl:read"]',
    "not json",
  ]) {
    expect(parseServiceScopeGrants(raw), raw).toEqual({ ok: false, grants: new Map() });
  }
});

it("adds granted scopes to the named key only, keeping its labels and teams", () => {
  const grants = parseServiceScopeGrants('{"cloud-platform-dev":["acl:read","acl:write"],"missing-key":["acl:read"]}').grants;
  const [dev, chief] = applyServiceScopeGrants([key("cloud-platform-dev"), key("cloud-chief")], grants);
  expect([...dev!.scopes].sort()).toEqual(["acl:read", "acl:write", "mesh:read", "mesh:write"]);
  expect(dev!.labels).toEqual({ role: "cloud" });
  expect(dev!.teams).toBeNull();
  expect([...chief!.scopes].sort()).toEqual(["mesh:read", "mesh:write"]);
});
