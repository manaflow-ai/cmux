// The Claude Code first-party OAuth contract, shared by every module that
// speaks to Anthropic on behalf of a Claude Max account: token refresh, the
// messages data plane, and the OAuth usage endpoint. One place to bump.
export const CLAUDE_OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
export const CLAUDE_OAUTH_TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
/** Claude Max OAuth access tokens are honored only alongside this beta. */
export const CLAUDE_OAUTH_BETA = "oauth-2025-04-20";
