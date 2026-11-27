export interface CliTeam {
    teamId: string;
    /**
     * Sandbox account behind the team (`acct-...`), the id the dashboard shows
     * in its URLs. Absent for logins that predate the CLI storing it.
     */
    accountId?: string | null;
    name: string;
    role: string;
}
export interface CliUser {
    id: string;
    email: string | null;
    displayName: string | null;
}
export interface CliConfig {
    version: 2;
    refreshToken?: string;
    activeTeamId?: string;
    defaultTeamId?: string;
    teams: CliTeam[];
    user?: CliUser;
    dashboardUrl?: string;
    /**
     * API key for an anonymous free-tier account created on this machine when no
     * login was present (`freestyle signup`, or the not-logged-in fallback).
     * `freestyle claim` attaches it to a real login.
     */
    anonymousApiKey?: string;
    anonymousAccountId?: string;
}
export declare function configPath(): string;
export declare function emptyConfig(): CliConfig;
export declare function readConfig(): CliConfig;
export declare function writeConfig(config: CliConfig): void;
export declare function updateConfig(update: Partial<CliConfig>): CliConfig;
export declare function deleteConfig(): boolean;
/** The team the next command would target, before it is looked up. */
export declare function teamSelector(selector: string | undefined, config?: CliConfig): string | undefined;
/** Match a team by Stack team id, account id (`acct-...`), or name. */
export declare function matchTeam(teams: CliTeam[], value: string): CliTeam | null;
export declare function resolveStoredTeam(selector: string | undefined, config?: CliConfig): CliTeam | null;
/**
 * Explain a failed lookup. Naming a team that does not resolve is a different
 * mistake from naming none at all, and either way the answer is the list of
 * teams — printing it beats sending the reader off to another command.
 */
export declare function teamLookupError(selector: string | undefined, teams?: CliTeam[]): Error;
//# sourceMappingURL=config.d.ts.map