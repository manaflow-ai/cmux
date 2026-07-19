import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";
import {
  insecureLoopbackMinterAllowed,
  parseIrohMinterUrl,
  type IrohMinterUrlPolicy,
} from "../services/iroh/minterUrlPolicy";

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
const irohMinterUrlPolicy: IrohMinterUrlPolicy = {
  allowInsecureLoopback:
    trimEnv(process.env.CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER) === "1",
  deploymentEnvironment:
    process.env.VERCEL_ENV ?? process.env.NODE_ENV ?? "development",
  isVercelDeployment: process.env.VERCEL === "1",
};
const requireVercelNonPreviewValue = (
  name: string,
  schema: z.ZodString = z.string().min(1),
): z.ZodType<string | undefined> =>
  schema.optional().superRefine((value, context) => {
    if (isVercelNonPreviewDeployment && !value) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: `${name} is required for deployed non-preview runtimes`,
      });
    }
  });
const requireVercelRelayValue = (
  schema: z.ZodString = z.string().min(1),
): z.ZodType<string | undefined> =>
  schema.optional().superRefine((value, context) => {
    if (isVercelNonPreviewDeployment && !value) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Self-hosted relay runtime configuration is incomplete",
      });
    }
  });
const privateRelayEnvNames = new Set([
  "CMUX_RELAY_JWT_PRIVATE_KEY_PEM",
  "CMUX_RELAY_POLICY_KEY_ID",
  "CMUX_RELAY_POLICY_PRIVATE_KEY_PEM",
  "CMUX_RELAY_TOKEN_RATE_LIMIT_ID",
]);
const publicEnvValidationIssues = (issues: readonly unknown[]): readonly unknown[] => {
  const publicIssues: unknown[] = [];
  let hasPrivateRelayIssue = false;
  for (const issue of issues) {
    const path = (issue as { path?: unknown } | null)?.path;
    const firstSegment = Array.isArray(path) ? path[0] : undefined;
    const pathKey = typeof firstSegment === "string"
      ? firstSegment
      : typeof firstSegment === "object" && firstSegment !== null && "key" in firstSegment
      ? String((firstSegment as { key: unknown }).key)
      : undefined;
    if (pathKey && privateRelayEnvNames.has(pathKey)) {
      hasPrivateRelayIssue = true;
    } else {
      publicIssues.push(issue);
    }
  }
  if (hasPrivateRelayIssue) {
    publicIssues.push({
      code: "custom",
      message: "Self-hosted relay runtime configuration is incomplete",
      path: ["relayRuntimeConfiguration"],
    });
  }
  return publicIssues;
};
const localDevelopmentOptIn = (name: string) =>
  z.enum(["0", "1"]).optional().superRefine((value, context) => {
    if (
      value === "1" &&
      !insecureLoopbackMinterAllowed({
        ...irohMinterUrlPolicy,
        allowInsecureLoopback: true,
      })
    ) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: `${name} is only allowed in local development`,
      });
    }
  });
const irohMinterUrl = z.string().url().superRefine((value, context) => {
  try {
    parseIrohMinterUrl(value, irohMinterUrlPolicy);
  } catch {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message:
        "CMUX_IROH_MINT_URL must use HTTPS, except for an opted-in local loopback development minter",
    });
  }
});
const irohBindingLimit = z.string().regex(/^[1-9][0-9]{0,3}$/).superRefine((value, context) => {
  if (Number(value) > 4_096) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Iroh binding limits must not exceed 4096",
    });
  }
});
const requireVercelProductionValue = (name: string): z.ZodType<string | undefined> =>
  z.string().min(1).optional().superRefine((value, context) => {
    if (isVercelProductionDeployment && !value) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: `${name} is required for Vercel production runtimes`,
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
    CMUX_ANALYTICS_RATE_LIMIT_ID: requireVercelProductionValue("CMUX_ANALYTICS_RATE_LIMIT_ID"),
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
    // Direct Stripe billing for cmux Pro. Optional: when unset, checkout is
    // unavailable.
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
    // Iroh trust broker. The Services API key deliberately has no TypeScript
    // env entry: only the isolated Rust relay minter may hold it. These values
    // are server-only and routes fail closed when an operation's key is absent.
    CMUX_IROH_LAN_DISCOVERY_SECRET_B64: requireVercelNonPreviewValue(
      "CMUX_IROH_LAN_DISCOVERY_SECRET_B64",
      z.string().max(512).regex(/^[A-Za-z0-9+/]{43,}={0,2}$/),
    ),
    CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64: requireVercelNonPreviewValue(
      "CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64",
      z.string().max(512).regex(/^[A-Za-z0-9+/]{43,}={0,2}$/),
    ),
    CMUX_IROH_GRANT_SIGNING_KEY_P8: requireVercelNonPreviewValue(
      "CMUX_IROH_GRANT_SIGNING_KEY_P8",
      z.string().min(64).max(16_384),
    ),
    CMUX_IROH_GRANT_SIGNING_KID: requireVercelNonPreviewValue(
      "CMUX_IROH_GRANT_SIGNING_KID",
      z.string().regex(/^[A-Za-z0-9._-]{1,64}$/),
    ),
    CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON: requireVercelNonPreviewValue(
      "CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON",
      z.string().min(2).max(32_768),
    ),
    // Optional compatibility path for n0-hosted relay credentials. The
    // self-hosted fleet mints endpoint-bound JWTs through /api/relay/token.
    CMUX_IROH_MINT_URL: irohMinterUrl.optional(),
    CMUX_IROH_MINT_HMAC_SECRET_B64:
      z.string().max(512).regex(/^[A-Za-z0-9+/]{43,}={0,2}$/).optional(),
    CMUX_IROH_RATE_LIMIT_ID: requireVercelNonPreviewValue("CMUX_IROH_RATE_LIMIT_ID"),
    CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: localDevelopmentOptIn(
      "CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER",
    ),
    CMUX_IROH_DEV_BINDING_OVERRIDE_ENABLED: z.enum(["0", "1"]).optional(),
    CMUX_IROH_DEV_BINDING_OVERRIDE_USER_IDS: z.string().max(8_192).optional(),
    CMUX_IROH_DEV_BINDING_OVERRIDE_ENVIRONMENTS: z.string().max(256).optional(),
    CMUX_IROH_DEV_BINDING_ACCOUNT_LIMIT: irohBindingLimit.optional(),
    CMUX_IROH_DEV_BINDING_DEVICE_LIMIT: irohBindingLimit.optional(),
    // Self-hosted relay fleet. Preview and local builds remain credential-free,
    // while every deployed non-preview runtime must be able to mint endpoint-
    // bound credentials, sign the fleet policy, and enforce its account limit.
    CMUX_RELAY_JWT_PRIVATE_KEY_PEM: requireVercelRelayValue(
      z.string().min(64).max(16_384),
    ),
    CMUX_RELAY_POLICY_KEY_ID: requireVercelRelayValue(
      z.string().regex(/^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$/),
    ),
    CMUX_RELAY_POLICY_PRIVATE_KEY_PEM: requireVercelRelayValue(
      z.string().min(64).max(16_384),
    ),
    CMUX_RELAY_TOKEN_RATE_LIMIT_ID: requireVercelRelayValue(),
    // Optional dedicated rule. Preferences deliberately fall back to the token
    // rule so existing deployments keep one shared account-scoped limiter.
    CMUX_RELAY_PREFERENCES_RATE_LIMIT_ID: z.string().min(1).optional(),
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
    CMUX_IROH_LAN_DISCOVERY_SECRET_B64: trimEnv(process.env.CMUX_IROH_LAN_DISCOVERY_SECRET_B64),
    CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64: trimEnv(process.env.CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64),
    CMUX_IROH_GRANT_SIGNING_KEY_P8: trimEnv(process.env.CMUX_IROH_GRANT_SIGNING_KEY_P8),
    CMUX_IROH_GRANT_SIGNING_KID: trimEnv(process.env.CMUX_IROH_GRANT_SIGNING_KID),
    CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON: trimEnv(process.env.CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON),
    CMUX_IROH_MINT_URL: trimEnv(process.env.CMUX_IROH_MINT_URL),
    CMUX_IROH_MINT_HMAC_SECRET_B64: trimEnv(process.env.CMUX_IROH_MINT_HMAC_SECRET_B64),
    CMUX_IROH_RATE_LIMIT_ID: trimEnv(process.env.CMUX_IROH_RATE_LIMIT_ID),
    CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: trimEnv(
      process.env.CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER,
    ),
    CMUX_IROH_DEV_BINDING_OVERRIDE_ENABLED: trimEnv(process.env.CMUX_IROH_DEV_BINDING_OVERRIDE_ENABLED),
    CMUX_IROH_DEV_BINDING_OVERRIDE_USER_IDS: trimEnv(process.env.CMUX_IROH_DEV_BINDING_OVERRIDE_USER_IDS),
    CMUX_IROH_DEV_BINDING_OVERRIDE_ENVIRONMENTS: trimEnv(process.env.CMUX_IROH_DEV_BINDING_OVERRIDE_ENVIRONMENTS),
    CMUX_IROH_DEV_BINDING_ACCOUNT_LIMIT: trimEnv(process.env.CMUX_IROH_DEV_BINDING_ACCOUNT_LIMIT),
    CMUX_IROH_DEV_BINDING_DEVICE_LIMIT: trimEnv(process.env.CMUX_IROH_DEV_BINDING_DEVICE_LIMIT),
    CMUX_RELAY_JWT_PRIVATE_KEY_PEM: trimEnv(process.env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM),
    CMUX_RELAY_POLICY_KEY_ID: trimEnv(process.env.CMUX_RELAY_POLICY_KEY_ID),
    CMUX_RELAY_POLICY_PRIVATE_KEY_PEM: trimEnv(process.env.CMUX_RELAY_POLICY_PRIVATE_KEY_PEM),
    CMUX_RELAY_TOKEN_RATE_LIMIT_ID: trimEnv(process.env.CMUX_RELAY_TOKEN_RATE_LIMIT_ID),
    CMUX_RELAY_PREFERENCES_RATE_LIMIT_ID: trimEnv(
      process.env.CMUX_RELAY_PREFERENCES_RATE_LIMIT_ID,
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
    console.error("❌ Invalid environment variables:", publicEnvValidationIssues(issues));
    throw new Error("Invalid environment variables");
  },
});
