/**
 * The authenticated caller of one request. Authentication middleware provides
 * it; nothing else constructs one for a request.
 */
import { Context } from "effect";
import type { ApiKeyId, TenantId, UserId } from "../lib/ids.ts";
import type { Scope } from "./scopes.ts";

export type Actor =
  | { readonly kind: "session"; readonly userId: UserId }
  | { readonly kind: "api_key"; readonly keyId: ApiKeyId };

export interface Principal {
  readonly tenantId: TenantId;
  readonly actor: Actor;
  readonly scopes: ReadonlySet<Scope>;
  /** When set, the caller may reach only these public resource ids, even within its tenant. */
  readonly resourceAllowlist: ReadonlySet<string> | null;
  /** When the credential stops working: an API key's expiry; null for a session or a key without one. */
  readonly credentialExpiresAt: Date | null;
}

export class CurrentPrincipal extends Context.Tag("cmux-vm/CurrentPrincipal")<CurrentPrincipal, Principal>() {}

/** The audit/ownership `created_by` value for an actor. */
export const actorRef = (actor: Actor): string =>
  actor.kind === "session" ? `user:${actor.userId}` : `key:${actor.keyId}`;
