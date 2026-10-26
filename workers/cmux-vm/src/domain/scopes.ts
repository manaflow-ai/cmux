/**
 * API key scopes. A session (signed-in team member) gets every scope except
 * `admin`; an API key gets exactly the scopes it was issued with. No scope
 * implies another, except that a family scope (`snapshot:*`) stands for every
 * scope of its family (`snapshot:read`, `snapshot:write`).
 */
import { Schema } from "effect";

export const SCOPES = [
  "vm:read",
  "vm:write",
  "vm:network",
  "vm:exec",
  "vm:files",
  "vm:terminal",
  "snapshot:*",
  "snapshot:read",
  "snapshot:write",
  "domain:*",
  // Domains, verifications, certificates, TLS rules and forward-auth checks (cx-b4h.6); members of domain:*.
  "domain:read",
  "domain:write",
  "deploy:*",
  "git:*",
  // Mesh experiment (cx-0op): read meshes, change them, enroll a device, read and write the ACL.
  "mesh:read",
  "mesh:write",
  "mesh:join",
  "acl:read",
  "acl:write",
  "admin",
] as const;

export const Scope = Schema.Literal(...SCOPES);
export type Scope = typeof Scope.Type;

/** Response names can grow; authentication and key requests still use Scope. */
export const ReportedScope = Schema.String.annotations({
  description: "A permission name. Clients must preserve unfamiliar response names; unfamiliar names never grant authority.",
  jsonSchema: { type: "string", "x-extensible-enum": SCOPES },
});

export const SESSION_SCOPES: ReadonlySet<Scope> = new Set(SCOPES.filter((scope) => scope !== "admin"));

const isScope = Schema.is(Scope);

const FAMILIES: ReadonlyArray<readonly [Scope, ReadonlyArray<Scope>]> = [
  ["snapshot:*", ["snapshot:read", "snapshot:write"]],
  ["domain:*", ["domain:read", "domain:write"]],
];

/** Unknown scope strings in a stored key are dropped, never widened. A family scope adds its members. */
export function scopeSetOf(values: ReadonlyArray<string>): ReadonlySet<Scope> {
  const scopes = new Set(values.filter(isScope));
  for (const [family, members] of FAMILIES) {
    if (scopes.has(family)) for (const member of members) scopes.add(member);
  }
  return scopes;
}
