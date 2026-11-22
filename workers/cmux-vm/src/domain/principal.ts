/**
 * The authenticated caller of one request. Authentication middleware provides
 * it; nothing else constructs one for a request.
 */
import { Context } from "effect";
import type { ApiKeyId, TenantId, UserId } from "../lib/ids.ts";
import type { Scope } from "./scopes.ts";

export type Actor =
  | { readonly kind: "session"; readonly userId: UserId }
  | { readonly kind: "api_key"; readonly keyId: ApiKeyId }
  /** A cmux service key acting for the team its request named (cx-b4h.13). */
  | { readonly kind: "service"; readonly serviceId: string };

export interface Principal {
  readonly tenantId: TenantId;
  readonly actor: Actor;
  readonly scopes: ReadonlySet<Scope>;
  /** When set, the caller may reach only these public resource ids, even within its tenant. */
  readonly resourceAllowlist: ReadonlySet<string> | null;
  /** When the credential stops working: an API key's expiry; null for a session or a key without one. */
  readonly credentialExpiresAt: Date | null;
  /**
   * Set when a device signed this request with its install key (mesh M3/M4):
   * the request runs as `actor` (the device's owner), and the audit log
   * records the device as the actor and `actor` as its owner.
   */
  readonly actingDevice?: string;
  /**
   * Set for a service key (cx-b4h.13): the caller reaches only resources that
   * carry every one of these labels, and every VM it creates must carry them.
   */
  readonly requiredLabels?: Readonly<Record<string, string>>;
}

/** Whether `labels` carries every label the principal is limited to. */
export const carriesRequiredLabels = (principal: Principal, labels: Readonly<Record<string, string>>): boolean =>
  principal.requiredLabels === undefined || Object.entries(principal.requiredLabels).every(([key, value]) => labels[key] === value);

export class CurrentPrincipal extends Context.Tag("cmux-vm/CurrentPrincipal")<CurrentPrincipal, Principal>() {}

/** The audit/ownership `created_by` value for an actor. */
export const actorRef = (actor: Actor): string => {
  switch (actor.kind) {
    case "session":
      return `user:${actor.userId}`;
    case "api_key":
      return `key:${actor.keyId}`;
    case "service":
      return `service:${actor.serviceId}`;
  }
};

/** The audit actor of a request and the owner it acted for: a device-signed request is the device, for its owner. */
export const auditActorOf = (principal: Principal): { readonly actor: string; readonly ownerActor: string | null } =>
  principal.actingDevice === undefined
    ? { actor: actorRef(principal.actor), ownerActor: null }
    : { actor: `device:${principal.actingDevice}`, ownerActor: actorRef(principal.actor) };
