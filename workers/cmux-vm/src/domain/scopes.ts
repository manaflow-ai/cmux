/**
 * API key scopes. A session (signed-in team member) gets every scope except
 * `admin`; an API key gets exactly the scopes it was issued with. No scope
 * implies another.
 */
import { Schema } from "effect";

export const SCOPES = [
  "vm:read",
  "vm:write",
  "vm:exec",
  "vm:files",
  "vm:terminal",
  "snapshot:*",
  "domain:*",
  "deploy:*",
  "git:*",
  "admin",
] as const;

export const Scope = Schema.Literal(...SCOPES);
export type Scope = typeof Scope.Type;

export const SESSION_SCOPES: ReadonlySet<Scope> = new Set(SCOPES.filter((scope) => scope !== "admin"));

const isScope = Schema.is(Scope);

/** Unknown scope strings in a stored key are dropped, never widened. */
export function scopeSetOf(values: ReadonlyArray<string>): ReadonlySet<Scope> {
  return new Set(values.filter(isScope));
}
