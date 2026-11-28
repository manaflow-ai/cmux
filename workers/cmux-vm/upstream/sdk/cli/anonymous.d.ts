/**
 * The anonymous free-tier signup flow. Freestyle serves a single-use
 * attestation binary; running it produces an opaque token that the server
 * validates and — if the device/project looks like a real developer/agent —
 * exchanges for a brand-new free-tier account and an API key. No Stack login is
 * involved; the account is claimable later (`freestyle claim`).
 */
export interface AnonymousAccount {
    apiKey: string;
    accountId: string;
    tier: string;
    allocationBand?: string;
    grantedCredits?: number;
    guidance?: string;
}
export interface CreateAnonymousOptions {
    /** Gateway base URL; defaults to FREESTYLE_PROXY or the public API. */
    baseUrl?: string;
    /** Optional one-line description of what you're building. */
    useCase?: string;
}
/** Create a fresh anonymous free-tier account and return its API key. */
export declare function createAnonymousAccount(options?: CreateAnonymousOptions): Promise<AnonymousAccount>;
/**
 * Return the stored anonymous API key, creating (and persisting) an anonymous
 * account the first time. Used by the CLI's not-logged-in path so ordinary
 * commands "just work" without a login.
 */
export declare function ensureAnonymousApiKey(baseUrl?: string): Promise<string>;
//# sourceMappingURL=anonymous.d.ts.map