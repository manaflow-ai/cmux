export type SubrouterAccount = {
  readonly id: string;
  readonly kind: string;
  readonly label?: string | null;
  readonly createdAt?: string;
  readonly health?: {
    readonly ok: boolean;
    readonly message?: string;
  };
};

export type ClaudeAccountInput = {
  readonly provider: "claude";
  readonly label?: string;
  readonly claudeAiOauth: {
    readonly accessToken: string;
    readonly refreshToken: string;
    readonly expiresAt: number;
    readonly subscriptionType?: string;
    readonly rateLimitTier?: string;
  };
};

export type AnthropicApiKeyAccountInput = {
  readonly provider: "anthropic-apikey";
  readonly label?: string;
  readonly apiKey: string;
};

export type CodexAccountInput = {
  readonly provider: "codex";
  readonly label?: string;
  readonly tokens: {
    readonly accessToken: string;
    readonly refreshToken: string;
    readonly idToken: string;
    readonly accountID: string;
  };
};

export type OpenAiApiKeyAccountInput = {
  readonly provider: "openai-apikey";
  readonly label?: string;
  readonly apiKey: string;
};

export type SubrouterAccountInput =
  | ClaudeAccountInput
  | AnthropicApiKeyAccountInput
  | CodexAccountInput
  | OpenAiApiKeyAccountInput;

export type SubrouterCredentialLeaseInput = {
  readonly provider: "codex" | "claude";
  readonly agentType?: string;
  readonly sessionId: string;
  readonly userEmail?: string;
  readonly preferAccountId?: string;
  readonly model?: string;
  readonly requiredAuthMode?: "oauth" | "apikey";
};

export type SubrouterCredentialLease = {
  readonly leaseId: string;
  readonly accountId: string;
  readonly provider: "codex" | "claude";
  readonly authMode: "oauth" | "apikey";
  readonly token: string;
  readonly providerAccountId?: string;
  readonly label: string;
  readonly email?: string;
  readonly credentialGeneration: number;
  readonly issuedAt: string;
  readonly expiresAt: string;
  readonly credentialExpiresAt?: string;
};

export type SubrouterCredentialLeaseOutcome =
  | "success"
  | "unauthorized"
  | "rate_limited"
  | "provider_error";
