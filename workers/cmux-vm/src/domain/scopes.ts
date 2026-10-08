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
  "vm:exec",
  "vm:files",
  "vm:terminal",
  "snapshot:*",
  "snapshot:read",
  "snapshot:write",
  "domain:*",
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

export const SESSION_SCOPES: ReadonlySet<Scope> = new Set(SCOPES.filter((scope) => scope !== "admin"));

const isScope = Schema.is(Scope);

const FAMILIES: ReadonlyArray<readonly [Scope, ReadonlyArray<Scope>]> = [["snapshot:*", ["snapshot:read", "snapshot:write"]]];

/** Unknown scope strings in a stored key are dropped, never widened. A family scope adds its members. */
export function scopeSetOf(values: ReadonlyArray<string>): ReadonlySet<Scope> {
  const scopes = new Set(values.filter(isScope));
  for (const [family, members] of FAMILIES) {
    if (scopes.has(family)) for (const member of members) scopes.add(member);
  }
  return scopes;
}
