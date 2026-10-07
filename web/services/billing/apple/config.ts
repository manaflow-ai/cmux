// Configuration for iOS in-app purchases (docs/billing/ios-in-app-purchases.md).
// Every reader takes an explicit env record so tests never depend on the
// process environment.

// Type-only: pro.ts reads Apple entitlements, so a runtime import would cycle.
import type { PersonalPlanId } from "../pro";

type Env = Record<string, string | undefined>;

/** Where an Apple subscriber manages or cancels their subscription. */
export const APPLE_MANAGE_SUBSCRIPTIONS_URL = "https://apps.apple.com/account/subscriptions";

/** The App Store app; App Review purchases arrive from it in the Sandbox. */
export const APP_STORE_BUNDLE_ID = "com.cmux.app";
const DEFAULT_BUNDLE_IDS = [APP_STORE_BUNDLE_ID, "dev.cmux.app.beta"] as const;
const DEFAULT_APP_APPLE_ID = 6783338052;

/** Environments whose payloads carry an App Store signature. */
export const SIGNED_APPLE_ENVIRONMENTS = ["Production", "Sandbox"] as const;
export type SignedAppleEnvironment = (typeof SIGNED_APPLE_ENVIRONMENTS)[number];

/** Personal plans sold in the iOS app, highest first (one subscription group). */
export const APPLE_PLAN_IDS: readonly PersonalPlanId[] = ["max", "pro", "go"];

/**
 * App Store list price in USD per plan, used only for analytics estimates
 * when a transaction is in another currency. Keep in sync with the doc table.
 */
export const APPLE_USD_LIST_PRICE: Readonly<Record<PersonalPlanId, number>> = {
  go: 14.99,
  pro: 74.99,
  max: 299.99,
};

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
 * Whether a Sandbox subscription may grant a real plan here. Sandbox
 * purchases are free, so production grants them only for the App Store
 * bundle, which is how App Review exercises purchases. TestFlight builds of
 * the beta bundle stay unentitled in production. Other deployments grant
 * every Sandbox purchase. `APPLE_IAP_SANDBOX_ENTITLEMENTS` overrides with
 * `all`, `none`, or a comma-separated bundle list.
 */
export function appleEnvironmentGrantsEntitlement(
  input: { readonly environment: string; readonly bundleId: string },
  env: Env = process.env,
): boolean {
  if (input.environment === "Production") return true;
  if (input.environment !== "Sandbox") return false;
  const override = trimmed(env.APPLE_IAP_SANDBOX_ENTITLEMENTS);
  if (override === "all") return true;
  if (override === "none") return false;
  if (override) return list(override)?.includes(input.bundleId) ?? false;
  if (env.VERCEL_ENV === "production") return input.bundleId === APP_STORE_BUNDLE_ID;
  return true;
}

/** `<bundleId>.<plan>.monthly`, the product ID for one plan in one app. */
export function appleProductId(bundleId: string, planId: PersonalPlanId): string {
  return `${bundleId}.${planId}.monthly`;
}

/** The plan an Apple product sells, or null for a product this server does not know. */
export function planIdForAppleProduct(productId: unknown, bundleId: unknown): PersonalPlanId | null {
  if (typeof productId !== "string" || typeof bundleId !== "string") return null;
  return APPLE_PLAN_IDS.find((planId) => appleProductId(bundleId, planId) === productId) ?? null;
}
