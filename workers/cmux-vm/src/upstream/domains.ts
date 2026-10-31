/**
 * Provider domain, certificate, TLS rule and forward-auth operations, as
 * handlers see them; the implementation that holds the provider key is
 * src/upstream/live-domains.ts. These provider resources are account-wide, so
 * tenancy lives in cmux's tables: an existing resource is addressed only
 * through a TenantOwnsDomainResource proof (its provider id is the proof's
 * evidence), and a rule or forward-auth body only through a proof minted after
 * every policy check (src/proofs/tls-rule.ts).
 */
import { Context, Effect, Schema } from "effect";
import type { UpstreamId } from "../lib/ids.ts";
import type { TenantOwnsDomainResource } from "../proofs/domain-resource.ts";
import type { ForwardAuthAllowed, StaleChallenges, TlsRuleAllowed, VerifiableDomain } from "../proofs/tls-rule.ts";
import type { UpstreamError } from "./client.ts";

export const UpstreamCertificate = Schema.Struct({
  domain: Schema.String,
  wildcard: Schema.Boolean,
  active: Schema.Boolean,
  notAfter: Schema.String,
  generation: Schema.Number,
});
export type UpstreamCertificate = typeof UpstreamCertificate.Type;

export interface UpstreamChallenge extends Created {
  readonly recordName: string;
  readonly code: string;
}

/** A new provider resource: its id for cmux's table and nowhere else, and a cleanup bound to exactly it. */
export interface Created {
  readonly upstreamId: UpstreamId;
  /** Deletes exactly this new resource, for when it cannot be recorded. Never fails. */
  readonly discard: Effect.Effect<void>;
}

export interface UpstreamDomainsService {
  /** Issues a challenge for a domain the caller reserved. */
  readonly createVerification: <C>(domain: VerifiableDomain<C>) => Effect.Effect<UpstreamChallenge, UpstreamError>;
  /**
   * Checks exactly this challenge's own code. "pending" while DNS does not show it; "gone" when the provider no
   * longer has it. The provider names the challenge that verified the domain: it must be this one, or one of
   * `siblings` (the same tenant's other challenges for the same domain); any other answer is an error.
   */
  readonly verifyDomain: <C, R>(owns: TenantOwnsDomainResource<C, R>, siblings: ReadonlyArray<UpstreamId>) => Effect.Effect<"verified" | "pending" | "gone", UpstreamError>;
  /** Withdraws provider challenges whose rows cmux's table just removed. Best effort: never fails. */
  readonly withdrawStaleChallenges: <C>(stale: StaleChallenges<C>) => Effect.Effect<void>;
  /** Withdraws exactly this pending challenge. */
  readonly deleteVerification: <C, R>(owns: TenantOwnsDomainResource<C, R>) => Effect.Effect<"deleted" | "gone" | "verified", UpstreamError>;
  /** Every certificate of the account: the handler filters to the caller's domains. */
  readonly listCertificates: Effect.Effect<ReadonlyArray<UpstreamCertificate>, UpstreamError>;
  /** Requests a wildcard certificate for a domain the caller verified. "refused" when its DNS is not delegated. */
  readonly requestWildcard: <C>(domain: VerifiableDomain<C>) => Effect.Effect<UpstreamCertificate | "refused", UpstreamError>;
  readonly createTlsRule: <C>(rule: TlsRuleAllowed<C>) => Effect.Effect<Created, UpstreamError>;
  readonly getTlsRule: <C, R>(owns: TenantOwnsDomainResource<C, R>) => Effect.Effect<"present" | "gone", UpstreamError>;
  readonly updateTlsRule: <C, R>(owns: TenantOwnsDomainResource<C, R>, rule: TlsRuleAllowed<C>) => Effect.Effect<"updated" | "gone", UpstreamError>;
  readonly deleteTlsRule: <C, R>(owns: TenantOwnsDomainResource<C, R>) => Effect.Effect<"deleted" | "gone", UpstreamError>;
  readonly createForwardAuth: <C>(config: ForwardAuthAllowed<C>) => Effect.Effect<Created, UpstreamError>;
  readonly updateForwardAuth: <C, R>(owns: TenantOwnsDomainResource<C, R>, config: ForwardAuthAllowed<C>) => Effect.Effect<"updated" | "gone", UpstreamError>;
  readonly deleteForwardAuth: <C, R>(owns: TenantOwnsDomainResource<C, R>) => Effect.Effect<"deleted" | "gone" | "in_use", UpstreamError>;
}

export class UpstreamDomains extends Context.Tag("cmux-vm/UpstreamDomains")<UpstreamDomains, UpstreamDomainsService>() {}
