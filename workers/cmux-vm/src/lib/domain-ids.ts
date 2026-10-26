/**
 * Public ids of the domain and TLS resources (migration 0018). Like every
 * public id they are opaque: a kind prefix plus 26 base32 characters, with no
 * provider information. The provider's ids for the same resources stay in the
 * database and in minted proofs (src/proofs/domain-resource.ts).
 */
import { Schema } from "effect";
import { randomIdBody } from "./ids.ts";

const opaque = (prefix: string) => new RegExp(`^${prefix}[0-9abcdefghjkmnpqrstvwxyz]{26}$`);

/** A custom domain the tenant proved it controls. */
export const DomainId = Schema.String.pipe(Schema.pattern(opaque("dom_")), Schema.brand("DomainId"));
export type DomainId = typeof DomainId.Type;

/** One ownership challenge (a TXT record) for a domain. */
export const DomainVerificationId = Schema.String.pipe(Schema.pattern(opaque("dvr_")), Schema.brand("DomainVerificationId"));
export type DomainVerificationId = typeof DomainVerificationId.Type;

/** One TLS rule: a named session over a hostname, to or from the tenant's own VMs. */
export const TlsRuleId = Schema.String.pipe(Schema.pattern(opaque("tlsr_")), Schema.brand("TlsRuleId"));
export type TlsRuleId = typeof TlsRuleId.Type;

/** A reusable authorization check for public HTTP ingress. */
export const ForwardAuthId = Schema.String.pipe(Schema.pattern(opaque("fwa_")), Schema.brand("ForwardAuthId"));
export type ForwardAuthId = typeof ForwardAuthId.Type;

export const newDomainId = (): DomainId => DomainId.make("dom_" + randomIdBody());
export const newDomainVerificationId = (): DomainVerificationId => DomainVerificationId.make("dvr_" + randomIdBody());
export const newTlsRuleId = (): TlsRuleId => TlsRuleId.make("tlsr_" + randomIdBody());
export const newForwardAuthId = (): ForwardAuthId => ForwardAuthId.make("fwa_" + randomIdBody());

/** Malformed input is simply "not found". */
export const parseDomainId = Schema.decodeUnknownOption(DomainId);
export const parseDomainVerificationId = Schema.decodeUnknownOption(DomainVerificationId);
export const parseTlsRuleId = Schema.decodeUnknownOption(TlsRuleId);
export const parseForwardAuthId = Schema.decodeUnknownOption(ForwardAuthId);
