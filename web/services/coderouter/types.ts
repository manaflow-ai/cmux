export type CodeRouterProvider = "codex" | "opencode-go";

export type CodexCredential = {
  readonly provider: "codex";
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly idToken: string;
  readonly accountId: string;
  readonly email: string;
  readonly expiresAt: number;
};

export type OpenCodeGoCredential = {
  readonly provider: "opencode-go";
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly accountId: string;
  readonly email: string;
  readonly orgId?: string;
  readonly orgName?: string;
  readonly expiresAt: number;
};

export type CodeRouterCredential = CodexCredential | OpenCodeGoCredential;

export type VaultAccount = {
  readonly revision: number;
  readonly credential: CodeRouterCredential;
};

export type CodeRouterVault = {
  readonly version: 1;
  readonly accounts: Readonly<Record<string, VaultAccount>>;
};

export type CodeRouterAccountSummary = {
  readonly id: string;
  readonly provider: CodeRouterProvider;
  readonly providerAccountId: string;
  readonly label: string;
  readonly state: "active" | "refreshing" | "expired" | "broken";
  readonly credentialExpiresAt: string | null;
  readonly lastFailureCode: string | null;
  readonly cooldownUntil: string | null;
  /** Sessions bound to this account with traffic in the recent window. */
  readonly activeSessions: number;
};
