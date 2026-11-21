/**
 * API key scopes. A session (signed-in team member) gets every scope except
 * `admin` and the service-only scopes; an API key gets exactly the scopes it
 * was issued with, never a service-only one. No scope
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
  "deploy:*",
  "git:*",
  // Mesh experiment (cx-0op): read meshes, change them, enroll a device, read and write the ACL.
  "mesh:read",
  "mesh:write",
  "mesh:join",
  "acl:read",
  "acl:write",
  "admin",
  // Classic -> NEXT migration: import a classic VM as a snapshot. Service keys only (SERVICE_ONLY_SCOPES).
  "import:classic",
] as const;

export const Scope = Schema.Literal(...SCOPES);
export type Scope = typeof Scope.Type;

/** Response names can grow; authentication and key requests still use Scope. */
export const ReportedScope = Schema.String.annotations({
  description: "A permission name. Clients must preserve unfamiliar response names; unfamiliar names never grant authority.",
  jsonSchema: { type: "string", "x-extensible-enum": SCOPES },
});

/**
 * Scopes only a service key (a CMUX_VM_SERVICE_KEYS entry) may hold: no session gets them, no API key may be
 * issued with them, and a stored API key that names one gets nothing from it.
 */
export const SERVICE_ONLY_SCOPES: ReadonlySet<Scope> = new Set<Scope>(["import:classic"]);

export const SESSION_SCOPES: ReadonlySet<Scope> = new Set(SCOPES.filter((scope) => scope !== "admin" && !SERVICE_ONLY_SCOPES.has(scope)));

/** Scopes an API key may be issued with: every scope but the service-only ones. */
export const KEY_SCOPES = SCOPES.filter((scope) => !SERVICE_ONLY_SCOPES.has(scope));
export const KeyScope = Scope.pipe(
  Schema.filter((scope) => !SERVICE_ONLY_SCOPES.has(scope), { message: () => "service-only scopes cannot be issued to an API key" }),
);

const isScope = Schema.is(Scope);

const FAMILIES: ReadonlyArray<readonly [Scope, ReadonlyArray<Scope>]> = [["snapshot:*", ["snapshot:read", "snapshot:write"]]];

/**
 * The scopes of a stored API key. Unknown scope strings are dropped, never widened, and so are service-only
 * scopes (an API key never holds one). A family scope adds its members.
 */
export function scopeSetOf(values: ReadonlyArray<string>): ReadonlySet<Scope> {
  const scopes = new Set(values.filter(isScope).filter((scope) => !SERVICE_ONLY_SCOPES.has(scope)));
  for (const [family, members] of FAMILIES) {
    if (scopes.has(family)) for (const member of members) scopes.add(member);
  }
  return scopes;
}
