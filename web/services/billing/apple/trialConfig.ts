// Constants and configuration for the iOS Pro free trial. Kept free of
// database and network imports so the paywall and account-token code can read
// them cheaply.

import { appleServerApiCredentials, APP_STORE_BUNDLE_ID } from "./config";

type Env = Record<string, string | undefined>;

export const APPLE_TEAM_ID = "7WLXT3NR37";
/** The app whose devices and installs can get the trial. */
export const TRIAL_BUNDLE_ID = APP_STORE_BUNDLE_ID;
/** The `ios-paywall-v1` variant that offers the trial. */
export { IOS_TRIAL_VARIANT as TRIAL_PAYWALL_VARIANT } from "../paywall/experiments";
export const TRIAL_DAYS = 7;
/** A trial challenge is single use and expires after 5 minutes. */
export const TRIAL_CHALLENGE_TTL_MS = 5 * 60 * 1000;

/** What a trial grants, shown to the app and enforced by the Go guard. */
export const TRIAL_LIMITS = { machines: 1, vcpus: 2, memoryGb: 4, vmHours: 20 } as const;

/**
 * The trial needs App Attest (no key, the team and bundle are constants),
 * DeviceCheck (its own key) and the In-App Purchase key to sign the
 * introductory-offer JWS. Missing any of them, nobody is offered a trial.
 */
export function isTrialConfigured(env: Env = process.env): boolean {
  return Boolean(env.DEVICECHECK_KEY_ID?.trim() && env.DEVICECHECK_PRIVATE_KEY?.trim() && appleServerApiCredentials(env));
}

/**
 * A verified claim must be used by a trial purchase within this time. A
 * claim never used expires, so verifying many accounts on one iPhone and
 * buying later cannot reserve several trials for one device.
 */
export const TRIAL_CLAIM_TTL_MS = 60 * 60 * 1000;

/**
 * Development App Attest keys and the DeviceCheck development host need an
 * explicit opt-in (`APPLE_TRIAL_ALLOW_DEVELOPMENT=1`) and are never allowed
 * in production, so a deployment without `VERCEL_ENV` fails closed.
 */
export function trialAllowsDevelopment(env: Env = process.env): boolean {
  return env.APPLE_TRIAL_ALLOW_DEVELOPMENT === "1" && env.VERCEL_ENV !== "production";
}
