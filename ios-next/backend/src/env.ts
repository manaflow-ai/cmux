/**
 * Worker environment. Vars come from wrangler.toml, secrets from
 * `wrangler secret put`. Every secret is optional: a missing secret turns its
 * feature off instead of failing the Worker.
 */
export interface AppEnv {
  SIGNAL_ROOM: DurableObjectNamespace;
  EMAIL?: SendEmail;
  AUTH_LIMITER?: RateLimit;

  APPLE_AUDIENCES?: string;
  /** Comma list of Stack Auth project ids accepted by /auth/stack. */
  STACK_PROJECT_IDS?: string;
  OAUTH_REDIRECT_SCHEMES?: string;
  EMAIL_FROM?: string;

  JWT_SECRET?: string;
  TEST_LOGIN_SECRET?: string;
  /** Comma list of email domains allowed for /auth/test. Default `test.cmux.dev`. */
  TEST_LOGIN_EMAIL_DOMAINS?: string;

  DATABASE_HOST?: string;
  DATABASE_USERNAME?: string;
  DATABASE_PASSWORD?: string;
  /** Test only: "memory" selects the in-process store. */
  REPO_BACKEND?: string;

  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;

  GITHUB_CLIENT_ID?: string;
  GITHUB_CLIENT_SECRET?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
}

export function csv(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

export function dbConfigured(env: AppEnv): boolean {
  return env.REPO_BACKEND === "memory" || Boolean(env.DATABASE_HOST && env.DATABASE_USERNAME && env.DATABASE_PASSWORD);
}

export function emailConfigured(env: AppEnv): boolean {
  return Boolean(env.EMAIL && env.EMAIL_FROM);
}

export function turnConfigured(env: AppEnv): boolean {
  return Boolean(env.TURN_KEY_ID && env.TURN_KEY_API_TOKEN);
}

export type OAuthProvider = "github" | "google";

export function oauthConfigured(env: AppEnv, provider: OAuthProvider): boolean {
  if (provider === "github") return Boolean(env.GITHUB_CLIENT_ID && env.GITHUB_CLIENT_SECRET);
  return Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET);
}
