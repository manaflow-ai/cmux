import type { FreestyleClient } from "./client.js";
export type VerificationState = "pending" | "verified";
export interface DomainVerification {
    id: string;
    domain: string;
    verificationCode: string;
    /** Place `verificationCode` in a TXT record at this name, then verify. */
    recordName: string;
    state: VerificationState;
    /** When this challenge proved control; null while pending. */
    verifiedAt: string | null;
    createdAt: string;
}
export interface DomainOwnership {
    domain: string;
    createdAt: string;
}
/** A successful verification: ownership, plus which challenge proved it. */
export interface DomainVerified {
    domain: string;
    createdAt: string;
    verifiedBy: string;
}
export interface CertificateInfo {
    domain: string;
    wildcard: boolean;
    active: boolean;
    notAfter: string;
    generation: number;
}
/**
 * What your placeholder pages wear. A placeholder page is the edge's 404 for
 * a hostname under one of your verified domains that none of your TLS rules
 * serve; it reloads itself until a route appears.
 */
export interface PlaceholderBranding {
    /** An https URL of the logo. The visitor's browser loads it directly. */
    logoUrl: string;
    /** Named on the page in place of Freestyle; null = logo only. */
    productName: string | null;
    createdAt: string;
    updatedAt: string;
}
export interface SetPlaceholderBrandingOptions {
    /** An https URL of the logo, at most 2048 characters. */
    logoUrl: string;
    /** Named on the page in place of Freestyle, at most 64 characters. Omit for logo only. */
    productName?: string;
}
export interface ListVerificationsOptions {
    /** Narrow to one state. Omit for every challenge the account holds, verified records included. */
    state?: VerificationState;
}
/** The `freestyle.domains` namespace. */
export declare class DomainsNamespace {
    private readonly client;
    readonly verifications: DomainVerificationsNamespace;
    readonly certificates: DomainCertificatesNamespace;
    /** The branding on the 404 page for hostnames under your domains that nothing serves. */
    readonly placeholder: DomainPlaceholderNamespace;
    constructor(client: FreestyleClient);
    /**
     * List the domains you hold: those you verified, and any Freestyle
     * subdomain you have taken by publishing it.
     */
    list(): Promise<DomainOwnership[]>;
}
export declare class DomainVerificationsNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    /**
     * Issue a challenge. Publish the returned `verificationCode` as a TXT
     * record at `recordName`, then `complete()` it.
     */
    create(domain: string): Promise<DomainVerification>;
    list(options?: ListVerificationsOptions): Promise<DomainVerification[]>;
    /** Fetch a verification challenge by its id or its domain. */
    get(domainOrId: string): Promise<DomainVerification>;
    /**
     * Check DNS and record ownership. Addressed by id, only that challenge's
     * own code counts; use this when several people are verifying the same
     * domain.
     */
    complete(domainOrId: string): Promise<DomainVerified>;
    /**
     * Withdraw outstanding challenges; by domain this drops all of them. A
     * challenge that already verified is a permanent record and cannot be
     * deleted.
     */
    delete(domainOrId: string): Promise<void>;
}
export declare class DomainCertificatesNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    list(): Promise<CertificateInfo[]>;
    /**
     * Request an ongoing `*.domain` certificate. Requires
     * `_acme-challenge.<domain>` to be NS-delegated to Freestyle's
     * nameservers, since wildcards can only be proven over DNS.
     */
    createWildcard(domain: string): Promise<CertificateInfo>;
}
/** The `freestyle.domains.placeholder` namespace. */
export declare class DomainPlaceholderNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    /** Your placeholder branding, or `null` when pages carry the Freestyle default. */
    get(): Promise<PlaceholderBranding | null>;
    /**
     * Set the branding for every placeholder page under your verified domains,
     * including domains you verify later. Replaces any earlier setting.
     */
    set(options: SetPlaceholderBrandingOptions): Promise<PlaceholderBranding>;
    /** Remove your branding; pages go back to the Freestyle default. */
    delete(): Promise<void>;
}
//# sourceMappingURL=domains.d.ts.map