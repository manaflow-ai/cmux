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
