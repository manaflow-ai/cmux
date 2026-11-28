// Configuration for iOS in-app purchases (docs/billing/ios-in-app-purchases.md).
// Every reader takes an explicit env record so tests never depend on the
// process environment.

// Type-only: pro.ts reads Apple entitlements, so a runtime import would cycle.
import type { PersonalPlanId } from "../pro";
import { NEXT_MAX_PLAN_ID, NEXT_PLUS_PLAN_ID, NEXT_PRO_PLAN_ID, type NextPlanId } from "../nextPlans";

type Env = Record<string, string | undefined>;

/** Where an Apple subscriber manages or cancels their subscription. */
export const APPLE_MANAGE_SUBSCRIPTIONS_URL = "https://apps.apple.com/account/subscriptions";

/** The App Store app; App Review purchases arrive from it in the Sandbox. */
export const APP_STORE_BUNDLE_ID = "com.cmux.app";
/**
 * The App Store app first (the default for a request without a bundle header),
 * then the classic TestFlight beta and cmux INTERNAL (`dev.cmux.app.internal`,
 * App Store Connect 6791408425), the cmux-next TestFlight build. TestFlight
 * buys only in the Sandbox, which production grants solely for the App Store
 * bundle, so INTERNAL is answered `purchases_unavailable` there unless
 * `APPLE_IAP_SANDBOX_ENTITLEMENTS` names it.
 */
const DEFAULT_BUNDLE_IDS = [APP_STORE_BUNDLE_ID, "dev.cmux.app.beta", "dev.cmux.app.internal"] as const;
const DEFAULT_APP_APPLE_ID = 6783338052;

/** Environments whose payloads carry an App Store signature. */
export const SIGNED_APPLE_ENVIRONMENTS = ["Production", "Sandbox"] as const;
export type SignedAppleEnvironment = (typeof SIGNED_APPLE_ENVIRONMENTS)[number];

/**
 * The classic App Store bundle (cmux CLASSIC TestFlight). It sells the classic
 * plans only; every other accepted bundle is a cmux-next app and sells the
 * NEXT plans only.
 */
export const CLASSIC_APPLE_BUNDLE_ID = "dev.cmux.app.beta";

/** Classic personal plans sold in the classic app, highest first (one subscription group). */
export const APPLE_CLASSIC_PLAN_IDS: readonly PersonalPlanId[] = ["max", "pro", "go"];

/**
 * cmux NEXT plans sold in the cmux-next apps (`com.cmux.app`,
 * `dev.cmux.app.internal`), highest first: App Store levels Max 1, Pro 2,
 * Plus 3 in the same "cmux Plans" group. Each product grants exactly its own
 * NEXT plan (RFD 0037a); `go` never maps to `next_plus`.
 */
export const APPLE_NEXT_PLAN_IDS: readonly NextPlanId[] = [NEXT_MAX_PLAN_ID, NEXT_PRO_PLAN_ID, NEXT_PLUS_PLAN_ID];

/** Every plan an App Store product can grant. */
export type ApplePlanId = PersonalPlanId | NextPlanId;

/** Every plan an App Store product can grant, classic first. */
export const APPLE_PLAN_IDS: readonly ApplePlanId[] = [...APPLE_CLASSIC_PLAN_IDS, ...APPLE_NEXT_PLAN_IDS];

export function isApplePlanId(value: unknown): value is ApplePlanId {
  return typeof value === "string" && (APPLE_PLAN_IDS as readonly string[]).includes(value);
}

/** Whether a bundle is the classic app (classic plans) rather than a cmux-next app (NEXT plans). */
export function isClassicAppleBundleId(bundleId: string): boolean {
  return bundleId === CLASSIC_APPLE_BUNDLE_ID;
}

/** The plans one app sells, highest first: classic in the classic app, NEXT in the cmux-next apps. */
export function applePlanIdsForBundle(bundleId: string): readonly ApplePlanId[] {
  return isClassicAppleBundleId(bundleId) ? APPLE_CLASSIC_PLAN_IDS : APPLE_NEXT_PLAN_IDS;
}

/**
 * App Store list price in USD per plan, used only for analytics estimates
 * when a transaction is in another currency. App Store Connect sets the real
 * price; keep in sync with the doc table. The rule (RFD 0037a): the web price
 * / 0.7, rounded up to the next .99 App Store point, so NEXT Plus $20 is
 * $29.99 and classic Go $15 is $21.99.
 */
export const APPLE_USD_LIST_PRICE: Readonly<Record<ApplePlanId, number>> = {
  go: 21.99,
  pro: 74.99,
  max: 299.99,
  next_plus: 29.99,
  next_pro: 74.99,
  next_max: 299.99,
};

/** App Store billing periods, the last segment of a product ID. */
export const APPLE_BILLING_PERIODS = ["monthly", "yearly"] as const;
export type AppleBillingPeriod = (typeof APPLE_BILLING_PERIODS)[number];

/**
 * Periods each plan sells, matching the web prices (plans.ts, nextPlans.ts):
 * classic Pro and Max monthly or yearly, Go monthly only, and every NEXT plan
 * monthly only, as the web sells them.
 */
export const APPLE_PLAN_BILLING_PERIODS: Readonly<Record<ApplePlanId, readonly AppleBillingPeriod[]>> = {
  go: ["monthly"],
  pro: ["monthly", "yearly"],
  max: ["monthly", "yearly"],
  next_plus: ["monthly"],
  next_pro: ["monthly"],
  next_max: ["monthly"],
};

/**
 * USD estimate for one yearly charge when a transaction is in another
 * currency: the monthly list price with the web's 20% yearly discount
 * (12 months for the price of 9.6). Replace with the App Store yearly prices
 * once they are set.
 */
export function appleUsdListPrice(planId: ApplePlanId, period: AppleBillingPeriod): number {
  const monthly = APPLE_USD_LIST_PRICE[planId];
  return period === "yearly" ? Math.round(monthly * 9.6 * 100) / 100 : monthly;
}

export function isSignedAppleEnvironment(value: unknown): value is SignedAppleEnvironment {
  return value === "Production" || value === "Sandbox";
}

function trimmed(value: string | undefined): string | null {
  const result = value?.trim();
  return result ? result : null;
}

function list(value: string | undefined): string[] | null {
  const raw = trimmed(value);
  if (!raw) return null;
  const items = raw.split(",").map((item) => item.trim()).filter(Boolean);
  return items.length > 0 ? items : null;
}

/** Bundle IDs whose transactions and notifications this server accepts. */
export function appleBundleIds(env: Env = process.env): readonly string[] {
  return list(env.APPLE_IAP_BUNDLE_IDS) ?? DEFAULT_BUNDLE_IDS;
}

export function isAcceptedAppleBundleId(bundleId: unknown, env: Env = process.env): bundleId is string {
  return typeof bundleId === "string" && appleBundleIds(env).includes(bundleId);
}

/** Apple ID of the App Store app; required to verify Production payloads. */
export function appleAppAppleId(env: Env = process.env): number {
  const raw = trimmed(env.APPLE_IAP_APP_APPLE_ID);
  const parsed = raw ? Number(raw) : DEFAULT_APP_APPLE_ID;
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : DEFAULT_APP_APPLE_ID;
}

/**
 * OCSP revocation checks against Apple, on in production deployments.
 * `APPLE_IAP_ONLINE_CHECKS=0|1` overrides.
 */
export function appleOnlineChecksEnabled(env: Env = process.env): boolean {
  const override = trimmed(env.APPLE_IAP_ONLINE_CHECKS);
  if (override === "1") return true;
  if (override === "0") return false;
  return env.VERCEL_ENV === "production";
}

export type AppleServerApiCredentials = {
  readonly keyId: string;
  readonly issuerId: string;
  readonly privateKey: string;
};

const SERVER_API_ENV_NAMES = ["APPLE_IAP_KEY_ID", "APPLE_IAP_ISSUER_ID", "APPLE_IAP_PRIVATE_KEY"] as const;

/** Server API env names this deployment is missing (empty when the key is configured). */
export function missingAppleServerApiEnv(env: Env = process.env): readonly string[] {
  return SERVER_API_ENV_NAMES.filter((name) => trimmed(env[name]) === null);
}

/**
 * Production must have the App Store Server API key: without it the client's
 * own transaction is trusted, missed renewals cannot be re-checked, and lost
 * notifications cannot be backfilled. The cron reports a missing key loudly.
 */
export function appleServerApiRequired(env: Env = process.env): boolean {
  return env.VERCEL_ENV === "production";
}

export type AppleServerApiStatus = {
  readonly appleServerApi: "configured" | "missing";
  /** Whether this deployment must have it (production). */
  readonly required: boolean;
  /** Names of the missing env values, never their contents. */
  readonly missingEnv: readonly string[];
};

/** The key's presence as server start and the admin analytics endpoint report it. */
export function appleServerApiStatus(env: Env = process.env): AppleServerApiStatus {
  const missingEnv = missingAppleServerApiEnv(env);
  return {
    appleServerApi: missingEnv.length === 0 ? "configured" : "missing",
    required: appleServerApiRequired(env),
    missingEnv,
  };
}

/** App Store Server API key, or null when this deployment has none. */
export function appleServerApiCredentials(env: Env = process.env): AppleServerApiCredentials | null {
  const keyId = trimmed(env.APPLE_IAP_KEY_ID);
  const issuerId = trimmed(env.APPLE_IAP_ISSUER_ID);
  // Vercel stores multi-line values verbatim; tolerate escaped newlines too.
  const privateKey = trimmed(env.APPLE_IAP_PRIVATE_KEY)?.replaceAll("\\n", "\n") ?? null;
  if (!keyId || !issuerId || !privateKey) return null;
  return { keyId, issuerId, privateKey };
}

/**
 * Lowercased cmux account emails whose Sandbox purchases of the App Store
 * bundle grant a plan in production (`APPLE_IAP_SANDBOX_ACCOUNT_EMAILS`,
 * comma-separated). App Review's demo account must be listed, or App Review
 * sees no products.
 */
export function appleSandboxAccountEmails(env: Env = process.env): readonly string[] {
  return (list(env.APPLE_IAP_SANDBOX_ACCOUNT_EMAILS) ?? []).map((email) => email.toLowerCase());
}

/**
 * Vercel project of cmux-staging.vercel.app. Staging is its own project deployed
 * to that project's production environment, so it also runs with
 * `VERCEL_ENV=production`; keep in step with scripts/cloud-vm/projects.mjs.
 */
const STAGING_VERCEL_PROJECT_ID = "prj_804LTAUdOwulMvEfcmfnU8bvGo3T";

/**
 * Whether this is the production cmux deployment, whose Sandbox grants are
 * limited. Staging is excluded by its project ID; a production deployment of
 * an unknown project counts as production, the stricter side.
 */
function isProductionSandboxPolicy(env: Env): boolean {
  return env.VERCEL_ENV === "production" && env.VERCEL_PROJECT_ID !== STAGING_VERCEL_PROJECT_ID;
}

/**
 * Whether the Sandbox decision depends on the cmux account's email. True only
 * in a production deployment without an `APPLE_IAP_SANDBOX_ENTITLEMENTS`
 * override, so other callers never need to read the email.
 */
export function appleSandboxGrantNeedsAccountEmail(env: Env = process.env): boolean {
  return isProductionSandboxPolicy(env) && trimmed(env.APPLE_IAP_SANDBOX_ENTITLEMENTS) === null;
}

/**
 * Whether a Sandbox subscription may grant a real plan here. Sandbox
 * purchases are free, so production grants them only for the App Store
 * bundle and only to cmux accounts in `APPLE_IAP_SANDBOX_ACCOUNT_EMAILS`
 * (App Review's demo account and the team's own testers). Any other TestFlight
 * tester stays unentitled. Other deployments, staging included, grant every
 * Sandbox purchase.
 * `APPLE_IAP_SANDBOX_ENTITLEMENTS` overrides both with `all`, `none`, or a
 * comma-separated bundle list, and then the email list is not consulted.
 */
export function appleEnvironmentGrantsEntitlement(
  input: { readonly environment: string; readonly bundleId: string; readonly accountEmail?: string | null },
  env: Env = process.env,
): boolean {
  if (input.environment === "Production") return true;
  if (input.environment !== "Sandbox") return false;
  const override = trimmed(env.APPLE_IAP_SANDBOX_ENTITLEMENTS);
  if (override === "all") return true;
  if (override === "none") return false;
  if (override) return list(override)?.includes(input.bundleId) ?? false;
  if (!isProductionSandboxPolicy(env)) return true;
  if (input.bundleId !== APP_STORE_BUNDLE_ID) return false;
  const email = input.accountEmail?.trim().toLowerCase();
  return email ? appleSandboxAccountEmails(env).includes(email) : false;
}

/**
 * Whether any account's Sandbox purchase of `bundleId` can grant a plan in
 * this deployment (the account allowlist aside): appleEnvironmentGrantsEntitlement
 * without the email check. The notification backfill reads Sandbox history
 * only for these bundles.
 */
export function appleSandboxMayGrant(bundleId: string, env: Env = process.env): boolean {
  const override = trimmed(env.APPLE_IAP_SANDBOX_ENTITLEMENTS);
  if (override === "all") return true;
  if (override === "none") return false;
  if (override) return list(override)?.includes(bundleId) ?? false;
  if (env.VERCEL_ENV !== "production") return true;
  return bundleId === APP_STORE_BUNDLE_ID;
}

/** One App Store Server Notifications history to backfill from. */
export type AppleNotificationHistorySource = {
  readonly bundleId: string;
  readonly environment: SignedAppleEnvironment;
};

/**
 * Histories this deployment backfills: Production for every accepted bundle,
 * and Sandbox for the bundles whose Sandbox purchases can grant here (in
 * production, `com.cmux.app` only: App Review and allowlisted testers).
 */
export function appleNotificationHistorySources(env: Env = process.env): readonly AppleNotificationHistorySource[] {
  const sources: AppleNotificationHistorySource[] = [];
  for (const bundleId of appleBundleIds(env)) {
    sources.push({ bundleId, environment: "Production" });
    if (appleSandboxMayGrant(bundleId, env)) sources.push({ bundleId, environment: "Sandbox" });
  }
  return sources;
}

/** `<bundleId>.<plan>.<monthly|yearly>`, the product ID for one plan and period in one app. */
export function appleProductId(bundleId: string, planId: ApplePlanId, period: AppleBillingPeriod = "monthly"): string {
  return `${bundleId}.${planId}.${period}`;
}

/**
 * The plan and period an Apple product sells, or null for a product this
 * server does not know. Any plan's product ID is recognized in any accepted
 * bundle, so a product a bundle stopped selling keeps granting its own plan
 * for the people still renewing it.
 */
export function appleProductFor(
  productId: unknown,
  bundleId: unknown,
): { readonly planId: ApplePlanId; readonly billingPeriod: AppleBillingPeriod } | null {
  if (typeof productId !== "string" || typeof bundleId !== "string") return null;
  for (const planId of APPLE_PLAN_IDS) {
    for (const billingPeriod of APPLE_PLAN_BILLING_PERIODS[planId]) {
      if (appleProductId(bundleId, planId, billingPeriod) === productId) return { planId, billingPeriod };
    }
  }
  return null;
}

/** The plan an Apple product sells, or null for a product this server does not know. */
export function planIdForAppleProduct(productId: unknown, bundleId: unknown): ApplePlanId | null {
  return appleProductFor(productId, bundleId)?.planId ?? null;
}

/** The billing period of a known product ID (`monthly` when unknown). */
export function appleBillingPeriodForProduct(productId: string, bundleId: string): AppleBillingPeriod {
  return appleProductFor(productId, bundleId)?.billingPeriod ?? "monthly";
}
