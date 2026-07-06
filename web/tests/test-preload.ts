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
process.env.SKIP_ENV_VALIDATION = "1";
process.env.CMUX_PUSH_RATE_LIMIT_ID ??= "cmux-push-test";
process.env.RESEND_API_KEY ??= "cmux-feedback-test-resend-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "feedback-from@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "cmux-feedback-test";
