// Runs once before any test module loads (see bunfig.toml `[test].preload`).
//
// `@/app/env` builds its `env` object from `process.env` at module-load time
// via t3-env's createEnv. bun runs every test file in one process, so whichever
// test file first imports `@/app/env` (directly or through a route) freezes
// those values for the whole run. That made env-dependent suites order-dependent
// and flaky in CI — e.g. notifications-push-route asserts the push rate-limit
// fires, but `env.CMUX_PUSH_RATE_LIMIT_ID` froze to `undefined` whenever another
// suite imported env first. Pinning the deterministic test env here, before any
// import, removes the ordering dependency. Individual suites may still override
// these at their own top level.
function defaultBlankEnv(name: string, value: string) {
  if (!process.env[name]?.trim()) process.env[name] = value;
}

process.env.SKIP_ENV_VALIDATION = "1";
defaultBlankEnv("CMUX_PUSH_RATE_LIMIT_ID", "cmux-push-test");
defaultBlankEnv("RESEND_API_KEY", "re_test");
defaultBlankEnv("CMUX_FEEDBACK_FROM_EMAIL", "founders@manaflow.com");
defaultBlankEnv("CMUX_FEEDBACK_RATE_LIMIT_ID", "feedback-test");
defaultBlankEnv("STACK_SECRET_SERVER_KEY", "stack-secret");
defaultBlankEnv("NEXT_PUBLIC_STACK_PROJECT_ID", "00000000-0000-4000-8000-000000000000");
defaultBlankEnv("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY", "test-publishable-client-key");
defaultBlankEnv("SLACK_ENTERPRISE_WEBHOOK_URL", "https://slack.test/enterprise");
