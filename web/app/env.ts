import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

// Trim at the runtimeEnv source so every consumer — including paths that
// run when validation is skipped (VERCEL_ENV === "preview") — sees clean
// values. A trailing newline in Vercel env vars has tripped Stack Auth's
// UUID parser and malformed the stack-refresh-<project-id> cookie key.
const trimEnv = (value: string | undefined): string | undefined =>
  typeof value === "string" ? value.trim() : value;

const isDocsZone =
  process.env.CMUX_DOCS_CHANNEL === "release" ||
  process.env.CMUX_DOCS_CHANNEL === "nightly";
const skipEnvValidation =
  process.env.SKIP_ENV_VALIDATION === "1" ||
  process.env.VERCEL_ENV === "preview" ||
  isDocsZone;
const allowPreviewStackPlaceholders =
  process.env.VERCEL_ENV === "preview" || isDocsZone;
const isVercelNonPreviewDeployment =
  process.env.VERCEL === "1" &&
  typeof process.env.VERCEL_ENV === "string" &&
  process.env.VERCEL_ENV !== "preview" &&
  !isDocsZone;
const isVercelProductionDeployment =
  process.env.VERCEL === "1" &&
  process.env.VERCEL_ENV === "production" &&
  !isDocsZone;
const requireVercelNonPreviewValue = (
  name: string,
  schema: z.ZodType<string> = z.string().min(1),
): z.ZodType<string | undefined> =>
  schema.optional().superRefine((value, context) => {
    if (isVercelNonPreviewDeployment && !value) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: `${name} is required for deployed non-preview runtimes`,
      });
    }
  });
const requireVercelProductionValue = (
  name: string,
  schema: z.ZodType<string> = z.string().min(1),
): z.ZodType<string | undefined> =>
  schema.optional().superRefine((value, context) => {
    if (isVercelProductionDeployment && !value) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: `${name} is required for deployed production runtimes`,
      });
    }
  });
const retiredEnvValue = (
  name: string,
  replacement: string,
): z.ZodType<string | undefined> =>
  z.string().optional().superRefine((value, context) => {
    if (value) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: `${name} is retired; use ${replacement}`,
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
    // Rate-limit rule ids are all optional: an unset id means that route runs
    // without rate limiting (the operator removed the limits deliberately).
    CMUX_FEEDBACK_RATE_LIMIT_ID: z.string().min(1).optional(),
    CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: z.string().min(1).optional(),
    CMUX_ANALYTICS_RATE_LIMIT_ID: z.string().min(1).optional(),
    // Native ingress gates run before Stack verification, so provider outages
    // cannot turn reconnect/readiness fan-out into an auth-request storm.
    CMUX_PUSH_RATE_LIMIT_ID: z.string().min(1).optional(),
    CMUX_DEVICE_REGISTRY_RATE_LIMIT_ID: z.string().min(1).optional(),
    // The deployed handoff route fails closed when this limiter is absent.
    CMUX_APP_SESSION_HANDOFF_RATE_LIMIT_ID: z.string().min(1).optional(),
    STACK_SECRET_SERVER_KEY: z.string().min(1),
    // APNs push (iOS notifications). Optional: the app boots without them; the
    // push route returns a clear "not configured" error until they are set.
    // CMUX_APNS_KEY_P8 holds the .p8 PEM (literal "\n" escapes are normalized
    // by the sender).
    CMUX_APNS_KEY_P8: z.string().min(1).optional(),
    CMUX_APNS_KEY_ID: z.string().min(1).optional(),
    CMUX_APNS_TEAM_ID: z.string().min(1).optional(),
    // cmux Founder's Edition welcome email (Stripe webhook -> Resend). Optional:
    // the /api/stripe/founders-welcome route returns "not configured" until the
    // webhook signing secret is set. CMUX_FOUNDERS_FROM_EMAIL overrides the
    // sender (defaults to austin@manaflow.ai) so the verified Resend domain can
    // change without a code edit.
    STRIPE_FOUNDERS_WEBHOOK_SECRET: z.string().min(1).optional(),
    CMUX_FOUNDERS_FROM_EMAIL: z.string().email().optional(),
    CMUX_PRO_FROM_EMAIL: z.string().email().optional(),
    // Direct Stripe billing for cmux Pro. Optional: when unset, checkout is
    // unavailable.
    STRIPE_SECRET_KEY: z.string().min(1).optional(),
    STRIPE_WEBHOOK_SECRET: z.string().min(1).optional(),
    STRIPE_PRO_MONTHLY_PRICE_ID: z.string().min(1).optional(),
    // Deliberately distinct from the legacy STRIPE_PRO_YEARLY_PRICE_ID,
    // which can refer to the grandfathered $240/year price.
    STRIPE_PRO_YEARLY_PRICE_ID: retiredEnvValue(
      "STRIPE_PRO_YEARLY_PRICE_ID",
      "STRIPE_PRO_YEARLY_288_PRICE_ID",
    ),
    STRIPE_PRO_YEARLY_288_PRICE_ID: z.string().min(1).optional(),
    STRIPE_TEAM_MONTHLY_PRICE_ID: z.string().min(1).optional(),
    STRIPE_TEAM_YEARLY_PRICE_ID: z.string().min(1).optional(),
    CMUX_APP_PRICING_CHECKOUT_URL: z.string().url().optional(),
    CMUX_APP_PRICING_RELAY_SECRET: z.string().min(32).optional(),
    // App Store Connect API for server-side TestFlight enrollment. Optional:
    // the dashboard shows enrollment unavailable until these credentials are set.
    // ASC_PRIVATE_KEY accepts PEM contents with literal "\n" escapes;
    // ASC_PRIVATE_KEY_PATH is a local-dev fallback path.
    ASC_KEY_ID: z.string().min(1).optional(),
    ASC_ISSUER_ID: z.string().min(1).optional(),
    ASC_PRIVATE_KEY: z.string().min(1).optional(),
    ASC_PRIVATE_KEY_PATH: z.string().min(1).optional(),
    CMUX_TESTFLIGHT_APP_ID: z.string().min(1).optional(),
    CMUX_PRO_TESTFLIGHT_GROUP_ID: z.string().min(1).optional(),
    SENTRY_DSN: z.string().url().optional(),
    // Hosted coderouter requires an active personal cmux Pro subscription.
    // Self-hosted deployments leave this unset (or set it to "0").
    CODEROUTER_HOSTED_PRO_REQUIRED: requireVercelProductionValue(
      "CODEROUTER_HOSTED_PRO_REQUIRED",
      z.enum(["0", "1"]),
    ),
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
    // Temporary retirement credentials for DB-mapped tenants created before
    // hosted Stack onboarding. Remove after subrouter_tenants is empty.
    SUBROUTER_BASE_URL: z.string().url().optional(),
    SUBROUTER_ADMIN_TOKEN: z.string().min(1).max(1_024).optional(),
    SUBROUTER_HOSTED_URL: z.string().url().optional(),
    SUBROUTER_STACK_TENANT_DELETE_TOKEN: requireVercelNonPreviewValue(
      "SUBROUTER_STACK_TENANT_DELETE_TOKEN",
      z.string().min(32).max(1_024),
    ),
    SUBROUTER_ENFORCE_STACK_PERMISSIONS: requireVercelNonPreviewValue(
      "SUBROUTER_ENFORCE_STACK_PERMISSIONS",
      z.enum(["0", "1"]),
    ),
    SUBROUTER_ALLOWED_TEAM_IDS: requireVercelNonPreviewValue(
      "SUBROUTER_ALLOWED_TEAM_IDS",
      z.string().min(1).max(8_192),
    ),
    SUBROUTER_STACK_AUTH_TIMEOUT_MS: z.string()
      .regex(/^[1-9][0-9]{0,4}$/)
      .refine((value) => Number(value) <= 30_000, {
        message: "SUBROUTER_STACK_AUTH_TIMEOUT_MS must not exceed 30000",
      })
      .optional(),
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
    CMUX_ANALYTICS_RATE_LIMIT_ID: trimEnv(process.env.CMUX_ANALYTICS_RATE_LIMIT_ID),
    CMUX_PUSH_RATE_LIMIT_ID: trimEnv(process.env.CMUX_PUSH_RATE_LIMIT_ID),
    CMUX_DEVICE_REGISTRY_RATE_LIMIT_ID: trimEnv(
      process.env.CMUX_DEVICE_REGISTRY_RATE_LIMIT_ID,
    ),
    CMUX_APP_SESSION_HANDOFF_RATE_LIMIT_ID: trimEnv(
      process.env.CMUX_APP_SESSION_HANDOFF_RATE_LIMIT_ID,
    ),
    CMUX_APNS_KEY_P8: trimEnv(process.env.CMUX_APNS_KEY_P8),
    CMUX_APNS_KEY_ID: trimEnv(process.env.CMUX_APNS_KEY_ID),
    CMUX_APNS_TEAM_ID: trimEnv(process.env.CMUX_APNS_TEAM_ID),
    STRIPE_FOUNDERS_WEBHOOK_SECRET: trimEnv(process.env.STRIPE_FOUNDERS_WEBHOOK_SECRET),
    CMUX_FOUNDERS_FROM_EMAIL: trimEnv(process.env.CMUX_FOUNDERS_FROM_EMAIL),
    CMUX_PRO_FROM_EMAIL: trimEnv(process.env.CMUX_PRO_FROM_EMAIL),
    STRIPE_SECRET_KEY: trimEnv(process.env.STRIPE_SECRET_KEY),
    STRIPE_WEBHOOK_SECRET: trimEnv(process.env.STRIPE_WEBHOOK_SECRET),
    STRIPE_PRO_MONTHLY_PRICE_ID: trimEnv(process.env.STRIPE_PRO_MONTHLY_PRICE_ID),
    STRIPE_PRO_YEARLY_PRICE_ID: trimEnv(process.env.STRIPE_PRO_YEARLY_PRICE_ID),
    STRIPE_PRO_YEARLY_288_PRICE_ID: trimEnv(
      process.env.STRIPE_PRO_YEARLY_288_PRICE_ID,
    ),
    STRIPE_TEAM_MONTHLY_PRICE_ID: trimEnv(process.env.STRIPE_TEAM_MONTHLY_PRICE_ID),
    STRIPE_TEAM_YEARLY_PRICE_ID: trimEnv(process.env.STRIPE_TEAM_YEARLY_PRICE_ID),
    CMUX_APP_PRICING_CHECKOUT_URL: trimEnv(
      process.env.CMUX_APP_PRICING_CHECKOUT_URL,
    ),
    CMUX_APP_PRICING_RELAY_SECRET: trimEnv(
      process.env.CMUX_APP_PRICING_RELAY_SECRET,
    ),
    ASC_KEY_ID: trimEnv(process.env.ASC_KEY_ID),
    ASC_ISSUER_ID: trimEnv(process.env.ASC_ISSUER_ID),
    ASC_PRIVATE_KEY: trimEnv(process.env.ASC_PRIVATE_KEY),
    ASC_PRIVATE_KEY_PATH: trimEnv(process.env.ASC_PRIVATE_KEY_PATH),
    CMUX_TESTFLIGHT_APP_ID: trimEnv(process.env.CMUX_TESTFLIGHT_APP_ID),
    CMUX_PRO_TESTFLIGHT_GROUP_ID: trimEnv(process.env.CMUX_PRO_TESTFLIGHT_GROUP_ID),
    SENTRY_DSN: trimEnv(process.env.SENTRY_DSN),
    CODEROUTER_HOSTED_PRO_REQUIRED: trimEnv(
      process.env.CODEROUTER_HOSTED_PRO_REQUIRED,
    ),
    CRON_SECRET: trimEnv(process.env.CRON_SECRET),
    CMUX_ALERTS_SLACK_WEBHOOK_URL: trimEnv(process.env.CMUX_ALERTS_SLACK_WEBHOOK_URL),
    CMUX_VM_ALERT_CREATE_FAILURES_15M: trimEnv(process.env.CMUX_VM_ALERT_CREATE_FAILURES_15M),
    CMUX_VM_ALERT_EXPIRED_LEASES: trimEnv(process.env.CMUX_VM_ALERT_EXPIRED_LEASES),
    SLACK_WAITLIST_WEBHOOK_URL: trimEnv(process.env.SLACK_WAITLIST_WEBHOOK_URL),
    SLACK_ENTERPRISE_WEBHOOK_URL: trimEnv(process.env.SLACK_ENTERPRISE_WEBHOOK_URL),
    SUBROUTER_BASE_URL: trimEnv(process.env.SUBROUTER_BASE_URL),
    SUBROUTER_ADMIN_TOKEN: trimEnv(process.env.SUBROUTER_ADMIN_TOKEN),
    SUBROUTER_HOSTED_URL: trimEnv(process.env.SUBROUTER_HOSTED_URL),
    SUBROUTER_STACK_TENANT_DELETE_TOKEN: trimEnv(
      process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN,
    ),
    SUBROUTER_ENFORCE_STACK_PERMISSIONS: trimEnv(
      process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS,
    ),
    SUBROUTER_ALLOWED_TEAM_IDS: trimEnv(
      process.env.SUBROUTER_ALLOWED_TEAM_IDS,
    ),
    SUBROUTER_STACK_AUTH_TIMEOUT_MS: trimEnv(
      process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS,
    ),
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
  onValidationError: (issues) => {
    console.error("❌ Invalid environment variables:", issues);
    throw new Error("Invalid environment variables");
  },
});
