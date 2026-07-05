import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

// Trim at the runtimeEnv source so every consumer — including paths that
// run when validation is skipped (VERCEL_ENV === "preview") — sees clean
// values. A trailing newline in Vercel env vars has tripped Stack Auth's
// UUID parser and malformed the stack-refresh-<project-id> cookie key.
const trimEnv = (value: string | undefined): string | undefined =>
  typeof value === "string" ? value.trim() : value;

const skipEnvValidation =
  process.env.SKIP_ENV_VALIDATION === "1" ||
  process.env.VERCEL_ENV === "preview";
const allowPreviewStackPlaceholders = process.env.VERCEL_ENV === "preview";

const stackEnv = (
  value: string | undefined,
  fallback: string
): string | undefined => {
  const trimmed = trimEnv(value);
  if (trimmed) return trimmed;
  return allowPreviewStackPlaceholders ? fallback : undefined;
};

export const env = createEnv({
  server: {
    RESEND_API_KEY: z.string().min(1),
    CMUX_FEEDBACK_FROM_EMAIL: z.string().email(),
    CMUX_FEEDBACK_RATE_LIMIT_ID: z.string().min(1),
    STACK_SECRET_SERVER_KEY: z.string().min(1),
    // APNs push (iOS notifications). Optional: the app boots without them; the
    // push route returns a clear "not configured" error until they are set.
    // CMUX_APNS_KEY_P8 holds the .p8 PEM (literal "\n" escapes are normalized
    // by the sender).
    CMUX_APNS_KEY_P8: z.string().min(1).optional(),
    CMUX_APNS_KEY_ID: z.string().min(1).optional(),
    CMUX_APNS_TEAM_ID: z.string().min(1).optional(),
    CMUX_PUSH_RATE_LIMIT_ID: z.string().min(1).optional(),
    // cmux Founder's Edition welcome email (Stripe webhook -> Resend). Optional:
    // the /api/stripe/founders-welcome route returns "not configured" until the
    // webhook signing secret is set. CMUX_FOUNDERS_FROM_EMAIL overrides the
    // sender (defaults to austin@manaflow.ai) so the verified Resend domain can
    // change without a code edit.
    STRIPE_FOUNDERS_WEBHOOK_SECRET: z.string().min(1).optional(),
    CMUX_FOUNDERS_FROM_EMAIL: z.string().email().optional(),
    // Slack Incoming Webhook for the #website-waitlist channel. Optional: the
    // /api/waitlist route silently skips the Slack ping when it is unset.
    SLACK_WAITLIST_WEBHOOK_URL: z.string().url().optional(),
    SENTRY_DSN: z.string().url().optional(),
    CMUX_ALERTS_SLACK_WEBHOOK_URL: z.string().url().optional(),
    CRON_SECRET: z.string().min(1).optional(),
    CMUX_VM_ALERT_CREATE_FAILURES_15M: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_ALERT_EXPIRED_LEASES: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_PROBE_USER_ID: z.string().min(1).optional(),
    CMUX_VM_PROBE_TEAM_ID: z.string().min(1).optional(),
    CMUX_VM_PROBE_PLAN_ID: z.string().min(1).optional(),
    CMUX_VM_PROBE_PROVIDER: z.enum(["e2b", "freestyle", "daytona"]).optional(),
    CMUX_VM_PROBE_IMAGE: z.string().min(1).optional(),
    CMUX_VM_PROBE_MAX_ACTIVE_VMS: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_PROBE_CREATE_TIMEOUT_MS: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_PROBE_STATUS_TIMEOUT_MS: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_PROBE_EXEC_TIMEOUT_MS: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_PROBE_DESTROY_TIMEOUT_MS: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_PROBE_STATUS_POLL_MS: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_PROBE_STALE_REAP_MS: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_PROBE_FRESHNESS_STALE_MS: z.string().regex(/^\d+$/).optional(),
  },
  client: {
    NEXT_PUBLIC_STACK_PROJECT_ID: z.string().min(1),
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: z.string().min(1),
    NEXT_PUBLIC_SENTRY_DSN: z.string().url().optional(),
  },
  runtimeEnv: {
    RESEND_API_KEY: trimEnv(process.env.RESEND_API_KEY),
    CMUX_FEEDBACK_FROM_EMAIL: trimEnv(process.env.CMUX_FEEDBACK_FROM_EMAIL),
    CMUX_FEEDBACK_RATE_LIMIT_ID: trimEnv(process.env.CMUX_FEEDBACK_RATE_LIMIT_ID),
    CMUX_APNS_KEY_P8: trimEnv(process.env.CMUX_APNS_KEY_P8),
    CMUX_APNS_KEY_ID: trimEnv(process.env.CMUX_APNS_KEY_ID),
    CMUX_APNS_TEAM_ID: trimEnv(process.env.CMUX_APNS_TEAM_ID),
    CMUX_PUSH_RATE_LIMIT_ID: trimEnv(process.env.CMUX_PUSH_RATE_LIMIT_ID),
    STRIPE_FOUNDERS_WEBHOOK_SECRET: trimEnv(process.env.STRIPE_FOUNDERS_WEBHOOK_SECRET),
    CMUX_FOUNDERS_FROM_EMAIL: trimEnv(process.env.CMUX_FOUNDERS_FROM_EMAIL),
    SLACK_WAITLIST_WEBHOOK_URL: trimEnv(process.env.SLACK_WAITLIST_WEBHOOK_URL),
    SENTRY_DSN: trimEnv(process.env.SENTRY_DSN),
    NEXT_PUBLIC_SENTRY_DSN: trimEnv(process.env.NEXT_PUBLIC_SENTRY_DSN),
    CMUX_ALERTS_SLACK_WEBHOOK_URL: trimEnv(process.env.CMUX_ALERTS_SLACK_WEBHOOK_URL),
    CRON_SECRET: trimEnv(process.env.CRON_SECRET),
    CMUX_VM_ALERT_CREATE_FAILURES_15M: trimEnv(process.env.CMUX_VM_ALERT_CREATE_FAILURES_15M),
    CMUX_VM_ALERT_EXPIRED_LEASES: trimEnv(process.env.CMUX_VM_ALERT_EXPIRED_LEASES),
    CMUX_VM_PROBE_USER_ID: trimEnv(process.env.CMUX_VM_PROBE_USER_ID),
    CMUX_VM_PROBE_TEAM_ID: trimEnv(process.env.CMUX_VM_PROBE_TEAM_ID),
    CMUX_VM_PROBE_PLAN_ID: trimEnv(process.env.CMUX_VM_PROBE_PLAN_ID),
    CMUX_VM_PROBE_PROVIDER: trimEnv(process.env.CMUX_VM_PROBE_PROVIDER),
    CMUX_VM_PROBE_IMAGE: trimEnv(process.env.CMUX_VM_PROBE_IMAGE),
    CMUX_VM_PROBE_MAX_ACTIVE_VMS: trimEnv(process.env.CMUX_VM_PROBE_MAX_ACTIVE_VMS),
    CMUX_VM_PROBE_CREATE_TIMEOUT_MS: trimEnv(process.env.CMUX_VM_PROBE_CREATE_TIMEOUT_MS),
    CMUX_VM_PROBE_STATUS_TIMEOUT_MS: trimEnv(process.env.CMUX_VM_PROBE_STATUS_TIMEOUT_MS),
    CMUX_VM_PROBE_EXEC_TIMEOUT_MS: trimEnv(process.env.CMUX_VM_PROBE_EXEC_TIMEOUT_MS),
    CMUX_VM_PROBE_DESTROY_TIMEOUT_MS: trimEnv(process.env.CMUX_VM_PROBE_DESTROY_TIMEOUT_MS),
    CMUX_VM_PROBE_STATUS_POLL_MS: trimEnv(process.env.CMUX_VM_PROBE_STATUS_POLL_MS),
    CMUX_VM_PROBE_STALE_REAP_MS: trimEnv(process.env.CMUX_VM_PROBE_STALE_REAP_MS),
    CMUX_VM_PROBE_FRESHNESS_STALE_MS: trimEnv(process.env.CMUX_VM_PROBE_FRESHNESS_STALE_MS),
    NEXT_PUBLIC_STACK_PROJECT_ID: stackEnv(
      process.env.NEXT_PUBLIC_STACK_PROJECT_ID,
      "00000000-0000-4000-8000-000000000000"
    ),
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: stackEnv(
      process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
      "preview-publishable-client-key"
    ),
    STACK_SECRET_SERVER_KEY: stackEnv(
      process.env.STACK_SECRET_SERVER_KEY,
      "preview-secret-server-key"
    ),
  },
  skipValidation: skipEnvValidation,
});
