import type { CliTeam } from "./config.js";
/**
 * The dashboard is where account management lives: API keys and billing have
 * no public-API surface on purpose (a key must not be able to mint another
 * key, and billing handlers trust their caller for the account). The
 * dashboard's account routes accept the same short-lived Stack access token a
 * login already yields, sent as the `x-stack-auth` header, and authorize the
 * URL-addressed account by team membership — so these commands can target
 * `--team` without touching the team selected in anyone's browser.
 */
export interface LoginContext {
    accessToken: string;
    team: CliTeam;
    /** The team's sandbox account id (`acct-...`), always present here. */
    accountId: string;
    /** Dashboard origin, no trailing slash. */
    baseUrl: string;
}
/**
 * Resolve the login + team this command acts for. Requires a real login: an
 * API key deliberately cannot manage keys or billing, so `--api-key` is
 * refused outright rather than silently ignored, and the anonymous-account
 * fallback ordinary commands enjoy does not apply.
 */
export declare function resolveLoginContext(argv: {
    apiKey?: string;
    team?: string;
}): Promise<LoginContext>;
/** A dashboard API refusal, with the `{code, message}` the routes answer. */
export declare class DashboardApiError extends Error {
    readonly status: number;
    readonly code: string;
    constructor(status: number, code: string, message: string);
}
/**
 * One dashboard API call. `path` is absolute (`/api/...`); account-scoped
 * routes live under `/api/accounts/{accountId}/...`. A JSON body makes the
 * request a POST unless a method says otherwise; 204 answers `undefined`.
 */
export declare function dashboardFetch<T>(ctx: LoginContext, path: string, init?: {
    method?: string;
    body?: unknown;
}): Promise<T>;
/** A dashboard action that deliberately has no login or account context. */
export declare function publicDashboardFetch<T>(path: string, body: unknown): Promise<T>;
//# sourceMappingURL=dashboard.d.ts.map