import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

// Trim at the runtimeEnv source so every consumer — including paths that
// run when validation is skipped (VERCEL_ENV === "preview") — sees clean
// values. A trailing newline in Vercel env vars has tripped Stack Auth's
// UUID parser and malformed the stack-refresh-<project-id> cookie key.
const trimEnv = (value: string | undefined): string | undefined =>
  typeof value === "string" ? value.trim() : value;

const defaultSubrouterBaseUrl = (): string =>
  process.env.VERCEL_ENV === "production"
    ? "https://subrouter.cmux.dev"
    : "https://subrouter-staging.cmux.dev";

const skipEnvValidation =
  process.env.SKIP_ENV_VALIDATION === "1" ||
  process.env.VERCEL_ENV === "preview";
const allowPreviewStackPlaceholders = process.env.VERCEL_ENV === "preview";
export const STACK_LOCAL_DEV_SECRET_SERVER_KEY_PLACEHOLDER = "cmux-local-dev-placeholder";
export const STACK_PREVIEW_SECRET_SERVER_KEY_PLACEHOLDER = "preview-secret-server-key";
export const STACK_SECRET_SERVER_KEY_PLACEHOLDERS = new Set<string>([
  STACK_LOCAL_DEV_SECRET_SERVER_KEY_PLACEHOLDER,
  STACK_PREVIEW_SECRET_SERVER_KEY_PLACEHOLDER,
]);
const isVercelNonPreviewDeployment =
  process.env.VERCEL === "1" &&
  typeof process.env.VERCEL_ENV === "string" &&
  process.env.VERCEL_ENV !== "preview";
const requireVercelNonPreviewValue = (name: string): z.ZodType<string | undefined> =>
  z.string().min(1).optional().superRefine((value, context) => {
    if (isVercelNonPreviewDeployment && !value) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: `${name} is required for deployed non-preview runtimes`,
      });
    }
  });

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
    CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: requireVercelNonPreviewValue("CMUX_CLIENT_CONFIG_RATE_LIMIT_ID"),
    STACK_SECRET_SERVER_KEY: requireVercelNonPreviewValue("STACK_SECRET_SERVER_KEY"),
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
    // Direct Stripe billing for cmux Pro. Optional: when unset, checkout keeps
    // using the legacy Stack-hosted product flow.
    STRIPE_SECRET_KEY: z.string().min(1).optional(),
    STRIPE_WEBHOOK_SECRET: z.string().min(1).optional(),
    STRIPE_PRO_MONTHLY_PRICE_ID: z.string().min(1).optional(),
    STRIPE_PRO_YEARLY_PRICE_ID: z.string().min(1).optional(),
    STRIPE_TEAM_MONTHLY_PRICE_ID: z.string().min(1).optional(),
    // App Store Connect API for server-side TestFlight enrollment. Optional:
    // the dashboard shows enrollment unavailable until these credentials are set.
    // ASC_PRIVATE_KEY accepts PEM contents with literal "\n" escapes;
    // ASC_PRIVATE_KEY_PATH is a local-dev fallback path.
    ASC_KEY_ID: z.string().min(1).optional(),
    ASC_ISSUER_ID: z.string().min(1).optional(),
    ASC_PRIVATE_KEY: z.string().min(1).optional(),
    ASC_PRIVATE_KEY_PATH: z.string().min(1).optional(),
    CMUX_TESTFLIGHT_APP_ID: z.string().min(1).optional(),
    CMUX_TESTFLIGHT_GROUP_ID: z.string().min(1).optional(),
    SENTRY_DSN: z.string().url().optional(),
    CRON_SECRET: z.string().min(1).optional(),
    CMUX_ALERTS_SLACK_WEBHOOK_URL: z.string().url().optional(),
    CMUX_VM_ALERT_CREATE_FAILURES_15M: z.string().regex(/^\d+$/).optional(),
    CMUX_VM_ALERT_EXPIRED_LEASES: z.string().regex(/^\d+$/).optional(),
    // Slack Incoming Webhook for the #website-waitlist channel. Optional: the
    // /api/waitlist route silently skips the Slack ping when it is unset.
    SLACK_WAITLIST_WEBHOOK_URL: z.string().url().optional(),
    // Slack Incoming Webhook for Enterprise contact requests. Optional: the
    // /api/enterprise/contact route falls back to the waitlist webhook, then
    // skips Slack if neither is set.
    SLACK_ENTERPRISE_WEBHOOK_URL: z.string().url().optional(),
    SUBROUTER_BASE_URL: z.string().url().optional(),
    SUBROUTER_ADMIN_TOKEN: z.string().min(1).optional(),
    SUBROUTER_TENANT_KEY_SECRET: z.string().min(1).optional(),
  },
  client: {
    NEXT_PUBLIC_STACK_PROJECT_ID: z.string().min(1),
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: z.string().min(1),
  },
  runtimeEnv: {
    RESEND_API_KEY: trimEnv(process.env.RESEND_API_KEY),
    CMUX_FEEDBACK_FROM_EMAIL: trimEnv(process.env.CMUX_FEEDBACK_FROM_EMAIL),
    CMUX_FEEDBACK_RATE_LIMIT_ID: trimEnv(process.env.CMUX_FEEDBACK_RATE_LIMIT_ID),
    CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: trimEnv(process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID),
    CMUX_APNS_KEY_P8: trimEnv(process.env.CMUX_APNS_KEY_P8),
    CMUX_APNS_KEY_ID: trimEnv(process.env.CMUX_APNS_KEY_ID),
    CMUX_APNS_TEAM_ID: trimEnv(process.env.CMUX_APNS_TEAM_ID),
    CMUX_PUSH_RATE_LIMIT_ID: trimEnv(process.env.CMUX_PUSH_RATE_LIMIT_ID),
    STRIPE_FOUNDERS_WEBHOOK_SECRET: trimEnv(process.env.STRIPE_FOUNDERS_WEBHOOK_SECRET),
    CMUX_FOUNDERS_FROM_EMAIL: trimEnv(process.env.CMUX_FOUNDERS_FROM_EMAIL),
    STRIPE_SECRET_KEY: trimEnv(process.env.STRIPE_SECRET_KEY),
    STRIPE_WEBHOOK_SECRET: trimEnv(process.env.STRIPE_WEBHOOK_SECRET),
    STRIPE_PRO_MONTHLY_PRICE_ID: trimEnv(process.env.STRIPE_PRO_MONTHLY_PRICE_ID),
    STRIPE_PRO_YEARLY_PRICE_ID: trimEnv(process.env.STRIPE_PRO_YEARLY_PRICE_ID),
    STRIPE_TEAM_MONTHLY_PRICE_ID: trimEnv(process.env.STRIPE_TEAM_MONTHLY_PRICE_ID),
    ASC_KEY_ID: trimEnv(process.env.ASC_KEY_ID),
    ASC_ISSUER_ID: trimEnv(process.env.ASC_ISSUER_ID),
    ASC_PRIVATE_KEY: trimEnv(process.env.ASC_PRIVATE_KEY),
    ASC_PRIVATE_KEY_PATH: trimEnv(process.env.ASC_PRIVATE_KEY_PATH),
    CMUX_TESTFLIGHT_APP_ID: trimEnv(process.env.CMUX_TESTFLIGHT_APP_ID),
    CMUX_TESTFLIGHT_GROUP_ID: trimEnv(process.env.CMUX_TESTFLIGHT_GROUP_ID),
    SENTRY_DSN: trimEnv(process.env.SENTRY_DSN),
    CRON_SECRET: trimEnv(process.env.CRON_SECRET),
    CMUX_ALERTS_SLACK_WEBHOOK_URL: trimEnv(process.env.CMUX_ALERTS_SLACK_WEBHOOK_URL),
    CMUX_VM_ALERT_CREATE_FAILURES_15M: trimEnv(process.env.CMUX_VM_ALERT_CREATE_FAILURES_15M),
    CMUX_VM_ALERT_EXPIRED_LEASES: trimEnv(process.env.CMUX_VM_ALERT_EXPIRED_LEASES),
    SLACK_WAITLIST_WEBHOOK_URL: trimEnv(process.env.SLACK_WAITLIST_WEBHOOK_URL),
    SLACK_ENTERPRISE_WEBHOOK_URL: trimEnv(process.env.SLACK_ENTERPRISE_WEBHOOK_URL),
    SUBROUTER_BASE_URL: trimEnv(process.env.SUBROUTER_BASE_URL) ?? defaultSubrouterBaseUrl(),
    SUBROUTER_ADMIN_TOKEN: trimEnv(process.env.SUBROUTER_ADMIN_TOKEN),
    SUBROUTER_TENANT_KEY_SECRET: trimEnv(process.env.SUBROUTER_TENANT_KEY_SECRET),
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
      STACK_PREVIEW_SECRET_SERVER_KEY_PLACEHOLDER
    ),
  },
  skipValidation: skipEnvValidation,
});
