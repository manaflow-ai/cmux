// The iOS Pro free trial, server side. The trial is offered only to an
// account the server chose (assigned to the trial arm of `ios-paywall-v1`, on
// the free plan, never trialed) on a device the server verified:
//
// 1. `POST /api/billing/apple/trial/challenge` issues a single-use challenge.
// 2. `POST /api/billing/apple/trial/verify` checks App Attest (genuine app on
//    a genuine device), binds the attested key to the account, and reads the
//    device's DeviceCheck bit0 (this iPhone already started a trial, under
//    any Apple ID or cmux account). On success it records a verified claim
//    and signs the iOS 18.4+ introductory-offer eligibility JWS.
// 3. The trial is a separate product (`<bundle>.pro.trial.monthly`) with the
//    7-day free-trial introductory offer. A free-trial transaction grants the
//    limited trial entitlement only for an account with a verified claim
//    (apple/store.ts); bit0 is set when the trial starts, so an account that
//    never buys does not burn the device.
//
// Accepted race (coordinator decision 2026-10-15): two accounts on one iPhone
// that both verified within the claim TTL and start their trials within the
// same few seconds can both read bit0 = 0 before either sets it, so both get
// the trial. Closing it needs a device identity Apple does not give us
// (DeviceCheck tokens differ per call); the window is seconds and needs two
// cmux accounts and two Apple IDs on one device.

import { randomBytes } from "node:crypto";
import { IntroductoryOfferEligibilitySignatureCreator } from "@apple/app-store-server-library";

import { captureServerEvent, type ServerEventInput } from "../../analytics/serverEvents";
import { IOS_PAYWALL_EXPERIMENT } from "../paywall/iosPaywallV1";
import { servedPaywallVariant } from "../paywall/store";
import { AppAttestError, trialClientDataHash, verifyAssertion, verifyAttestation, type AppAttestApp } from "./appAttest";
import { appleServerApiCredentials, appleTrialProductId } from "./config";
import { deviceCheckClient, deviceCheckCredentials, type DeviceCheckClient } from "./deviceCheck";
import type { AppleSubscriptionRow, AppleSubscriptionWrite } from "./store";
import {
  APPLE_TEAM_ID,
  isTrialConfigured,
  TRIAL_BUNDLE_ID,
  TRIAL_CHALLENGE_TTL_MS,
  TRIAL_LIMITS,
  TRIAL_PAYWALL_VARIANT,
  trialAllowsDevelopment,
} from "./trialConfig";
import { databaseTrialStore, type TrialStore } from "./trialStore";

type Env = Record<string, string | undefined>;

export const TRIAL_APP: AppAttestApp = { teamId: APPLE_TEAM_ID, bundleId: TRIAL_BUNDLE_ID };

export type TrialIneligibleReason =
  | "trial_unavailable"
  | "challenge_invalid"
  | "attest_failed"
  | "device_key_in_use"
  | "not_offered"
  | "account_already_trialed"
  | "device_already_trialed";

export type TrialVerifyResponse = {
  readonly eligible: boolean;
  readonly introductoryOfferJWS: string | null;
  readonly reason: TrialIneligibleReason | null;
  readonly legacyTrialAllowed: boolean;
};

export type TrialVerifyOutcome =
  | { readonly status: 200; readonly body: TrialVerifyResponse }
  | { readonly status: 400 | 409; readonly body: { readonly error: string } };

/** Whether the account may be offered a trial, before any device proof. */
export type TrialAccountCheck = (userId: string) => Promise<boolean>;

export type TrialDependencies = {
  readonly store: TrialStore;
  readonly env: Env;
  readonly now: () => Date;
  /** Account-level eligibility: free plan, purchasable, App Store app, assigned to the trial arm. */
  readonly accountOffered: TrialAccountCheck;
  readonly deviceCheck: (environment: string) => DeviceCheckClient | null;
  readonly signIntroductoryOffer: (productId: string, appTransactionId: string) => string | null;
  /** Pinned App Attest root; tests inject a local chain. */
  readonly attestationRootPem?: string;
};

export function introductoryOfferSigner(env: Env): (productId: string, appTransactionId: string) => string | null {
  return (productId, appTransactionId) => {
    const credentials = appleServerApiCredentials(env);
    if (!credentials) return null;
    return new IntroductoryOfferEligibilitySignatureCreator(
      credentials.privateKey, credentials.keyId, credentials.issuerId, TRIAL_BUNDLE_ID,
    ).createSignature(productId, true, appTransactionId);
  };
}

export function defaultDeviceCheck(env: Env): (environment: string) => DeviceCheckClient | null {
  return (environment) => {
    const credentials = deviceCheckCredentials(env);
    if (!credentials) return null;
    return deviceCheckClient(credentials, { development: environment === "development" });
  };
}

const ineligible = (reason: TrialIneligibleReason): TrialVerifyOutcome =>
  ({ status: 200, body: { eligible: false, introductoryOfferJWS: null, reason, legacyTrialAllowed: false } });

/** `POST /api/billing/apple/trial/challenge`. */
export async function issueTrialChallenge(userId: string, deps: Pick<TrialDependencies, "store" | "now">): Promise<string> {
  const challenge = randomBytes(32).toString("base64");
  const now = deps.now();
  await deps.store.issueChallenge(userId, challenge, new Date(now.getTime() + TRIAL_CHALLENGE_TTL_MS), now);
  return challenge;
}

export type TrialVerifyRequest = {
  readonly challenge: string;
  readonly keyId: string;
  readonly attestation: string | null;
  readonly assertion: string | null;
  readonly deviceCheckToken: string;
  readonly productId: string;
  readonly appTransactionId: string | null;
};

const BASE64 = /^[A-Za-z0-9+/_-]+={0,2}$/;

function optionalBase64(value: unknown, max: number): string | null | undefined {
  if (value === null || value === undefined) return null;
  return typeof value === "string" && value.length > 0 && value.length <= max && BASE64.test(value) ? value : undefined;
}

/** The request body, or null when malformed. */
export function parseTrialVerifyRequest(body: unknown): TrialVerifyRequest | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const record = body as Record<string, unknown>;
  const challenge = optionalBase64(record.challenge, 128);
  const keyId = optionalBase64(record.keyId, 128);
  const attestation = optionalBase64(record.attestation, 16_384);
  const assertion = optionalBase64(record.assertion, 4_096);
  const deviceCheckToken = optionalBase64(record.deviceCheckToken, 8_192);
  const appTransactionId = record.appTransactionId === null || record.appTransactionId === undefined
    ? null
    : typeof record.appTransactionId === "string" && /^[0-9]{1,32}$/.test(record.appTransactionId) ? record.appTransactionId : undefined;
  if (!challenge || !keyId || attestation === undefined || assertion === undefined || !deviceCheckToken || appTransactionId === undefined) return null;
  if ((attestation === null) === (assertion === null)) return null;
  if (typeof record.productId !== "string") return null;
  return { challenge, keyId, attestation, assertion, deviceCheckToken, productId: record.productId, appTransactionId };
}

/** Runs an App Attest check; any failure of hostile input (not only AppAttestError) is a failed proof. */
function attestCheck<T>(check: () => T): { readonly ok: true; readonly value: T } | { readonly ok: false } {
  try {
    return { ok: true, value: check() };
  } catch (error) {
    console.warn("billing.trial.attest_failed", {
      reason: error instanceof AppAttestError ? error.reason : error instanceof Error ? error.name : "unknown",
    });
    return { ok: false };
  }
}

/** App Attest: an attestation binds a new key to the user; an assertion proves a known key. */
async function proveDevice(
  userId: string,
  request: TrialVerifyRequest,
  deps: TrialDependencies,
): Promise<{ readonly ok: true; readonly environment: string; readonly keyId: string } | { readonly ok: false; readonly outcome: TrialVerifyOutcome }> {
  const clientDataHash = trialClientDataHash(request.challenge, request.productId);
  const keyIdBytes = Buffer.from(request.keyId.replaceAll("-", "+").replaceAll("_", "/"), "base64");
  if (keyIdBytes.length !== 32) return { ok: false, outcome: ineligible("attest_failed") };
  // One spelling per key: base64 and base64url, padded or not, are the same key.
  const keyId = keyIdBytes.toString("base64");
  if (request.attestation) {
    const attested = attestCheck(() => verifyAttestation({
      attestation: Buffer.from(request.attestation!, "base64"),
      keyId: keyIdBytes,
      clientDataHash,
      app: TRIAL_APP,
      allowDevelopment: trialAllowsDevelopment(deps.env),
      now: deps.now(),
      rootCertificatePem: deps.attestationRootPem,
    }));
    if (!attested.ok) return { ok: false, outcome: ineligible("attest_failed") };
    const owner = await deps.store.bindAttestKey({
      keyId, userId, publicKeySpki: attested.value.publicKeySpki, environment: attested.value.environment,
    });
    return owner === userId
      ? { ok: true, environment: attested.value.environment, keyId }
      : { ok: false, outcome: ineligible("device_key_in_use") };
  }
  const key = await deps.store.attestKey(keyId);
  if (!key) return { ok: false, outcome: { status: 409, body: { error: "attest_key_unknown" } } };
  if (key.userId !== userId) return { ok: false, outcome: ineligible("device_key_in_use") };
  const signCount = attestCheck(() => verifyAssertion({
    assertion: Buffer.from(request.assertion!, "base64"),
    clientDataHash,
    publicKeySpki: key.publicKeySpki,
    previousSignCount: key.signCount,
    app: TRIAL_APP,
  }));
  if (!signCount.ok) return { ok: false, outcome: ineligible("attest_failed") };
  if (!await deps.store.advanceSignCount(key.keyId, signCount.value)) return { ok: false, outcome: ineligible("attest_failed") };
  return { ok: true, environment: key.environment, keyId };
}

/** `POST /api/billing/apple/trial/verify`. */
export async function verifyTrialEligibility(
  userId: string,
  request: TrialVerifyRequest,
  deps: TrialDependencies,
): Promise<TrialVerifyOutcome> {
  if (request.productId !== appleTrialProductId(TRIAL_BUNDLE_ID)) return { status: 400, body: { error: "invalid_product" } };
  if (!isTrialConfigured(deps.env)) return ineligible("trial_unavailable");
  if (!await deps.store.consumeChallenge(userId, request.challenge, deps.now())) return ineligible("challenge_invalid");
  const device = await proveDevice(userId, request, deps);
  if (!device.ok) return device.outcome;
  const claim = await deps.store.claim(userId);
  if (claim && claim.status !== "verified") return ineligible("account_already_trialed");
  if (!await deps.accountOffered(userId)) return ineligible("not_offered");
  const deviceCheck = deps.deviceCheck(device.environment);
  if (!deviceCheck) return ineligible("trial_unavailable");
  let bits;
  try {
    bits = await deviceCheck.queryBits(request.deviceCheckToken);
  } catch (error) {
    // Fail closed: without the device's history the trial could be repeated.
    console.warn("billing.trial.devicecheck_failed", { error: error instanceof Error ? error.message.slice(0, 200) : String(error) });
    return ineligible("trial_unavailable");
  }
  if (bits.bit0) return ineligible("device_already_trialed");
  if (!await deps.store.recordVerifiedClaim(userId, device.keyId, request.deviceCheckToken)) {
    return ineligible("account_already_trialed");
  }
  const jws = request.appTransactionId ? deps.signIntroductoryOffer(request.productId, request.appTransactionId) : null;
  return { status: 200, body: { eligible: true, introductoryOfferJWS: jws, reason: null, legacyTrialAllowed: true } };
}

// Trial lifecycle, from the subscription writes in apple/service.ts.

export type TrialLifecycleDependencies = {
  readonly store: Pick<TrialStore,
    "claim" | "markDeviceMarkAttempted" | "markDeviceMarked" | "markDeviceReused" | "settleSubscriptionPlan" | "pendingTrialSubscriptions">;
  readonly deviceCheck: (environment: string) => DeviceCheckClient | null;
  readonly attestKeyEnvironment: (keyId: string) => Promise<string | null>;
  readonly paywallVariant: (userId: string) => Promise<string | null>;
  readonly captureEvent: (input: ServerEventInput) => Promise<void>;
  /** Re-derives the user's plan after the trial settles to `go`. */
  readonly applyEntitlement: (userId: string) => Promise<void>;
  readonly now: () => Date;
};

export function defaultTrialLifecycleDependencies(env: Env = process.env): TrialLifecycleDependencies {
  const store = databaseTrialStore();
  return {
    store,
    deviceCheck: defaultDeviceCheck(env),
    attestKeyEnvironment: async (keyId) => (await store.attestKey(keyId))?.environment ?? null,
    paywallVariant: (userId) => servedPaywallVariant(userId, IOS_PAYWALL_EXPERIMENT),
    captureEvent: captureServerEvent,
    applyEntitlement: async (userId) => {
      const { applyPersonalPlanEntitlement } = await import("./applyEntitlement");
      await applyPersonalPlanEntitlement(userId);
    },
    now: () => new Date(),
  };
}

type TrialEvent = "trial_started" | "trial_converted" | "trial_cancelled";

/**
 * Which trial fact a subscription write represents, if any. `trial_started`
 * comes from settleTrialDevice when the device check grants the trial; a
 * write reports it only when it is the one that first shows `go` (a settle
 * that marked the device but did not finish).
 */
export function trialTransition(
  previous: AppleSubscriptionRow | null,
  current: AppleSubscriptionRow,
  notification: { readonly type: string | null; readonly subtype: string | null } | null,
): TrialEvent | null {
  const wasTrial = previous?.freeTrial === true && previous.planId === "go";
  if (current.freeTrial && current.planId === "go") {
    if (!wasTrial) return "trial_started";
    if (notification?.type === "DID_CHANGE_RENEWAL_STATUS" && notification.subtype === "AUTO_RENEW_DISABLED") return "trial_cancelled";
    if (current.status === "expired" || current.status === "revoked") return "trial_cancelled";
    return null;
  }
  if (!wasTrial) return null;
  if (!current.freeTrial && current.status === "active" && current.planId !== "trial_unverified") return "trial_converted";
  if (current.status === "expired" || current.status === "revoked") return "trial_cancelled";
  return null;
}

async function captureTrialEvent(event: TrialEvent, current: AppleSubscriptionRow, deps: TrialLifecycleDependencies): Promise<void> {
  const variant = await deps.paywallVariant(current.userId);
  await deps.captureEvent({
    event,
    distinctId: current.userId,
    insertId: `${event}:${current.originalTransactionId}`,
    properties: {
      source: "apple",
      plan_id: event === "trial_converted" ? current.planId : "pro",
      product_id: current.productId,
      environment: current.environment,
      original_transaction_id: current.originalTransactionId,
      trial_ends_at: event === "trial_converted" ? null : current.expiresAt?.toISOString() ?? null,
      paywall_experiment: variant ? IOS_PAYWALL_EXPERIMENT : null,
      paywall_variant: variant,
    },
  });
}

export type TrialSettlement = "granted" | "device_reused" | "unverified" | "pending" | "skipped";

/**
 * Settles a `trial_pending` subscription against the device: if the
 * iPhone's DeviceCheck bit0 is already set by another trial the trial grants
 * nothing; otherwise bit0 is set first and only then the trial is granted
 * (`go`). Fails closed: any DeviceCheck failure leaves it pending (no grant),
 * and the apple-notifications cron and every later write retry it.
 */
export async function settleTrialDevice(
  current: AppleSubscriptionRow,
  deps: TrialLifecycleDependencies,
): Promise<TrialSettlement> {
  if (!current.freeTrial || current.planId !== "trial_pending") return "skipped";
  const claim = await deps.store.claim(current.userId);
  if (!claim || claim.status !== "started" || claim.originalTransactionId !== current.originalTransactionId || !claim.deviceCheckToken) {
    await deps.store.settleSubscriptionPlan(current.originalTransactionId, "trial_unverified");
    return "unverified";
  }
  const client = deps.deviceCheck(await deps.attestKeyEnvironment(claim.keyId) ?? "production");
  if (!client) return "pending";
  try {
    if (!claim.deviceMarkedAt) {
      const bits = await client.queryBits(claim.deviceCheckToken);
      // bit0 already set and this claim never tried to set it: another trial used this iPhone.
      if (bits.bit0 && !claim.deviceMarkAttemptedAt) {
        await deps.store.markDeviceReused(current.userId);
        await deps.store.settleSubscriptionPlan(current.originalTransactionId, "trial_unverified");
        return "device_reused";
      }
      await deps.store.markDeviceMarkAttempted(current.userId, deps.now());
      if (!bits.bit0) await client.updateBits(claim.deviceCheckToken, { bit0: true });
      await deps.store.markDeviceMarked(current.userId, deps.now());
    }
    if (await deps.store.settleSubscriptionPlan(current.originalTransactionId, "go")) {
      await deps.applyEntitlement(current.userId);
      await captureTrialEvent("trial_started", { ...current, planId: "go" }, deps);
    }
    return "granted";
  } catch (error) {
    console.warn("billing.trial.device_settle_failed", {
      originalTransactionId: current.originalTransactionId,
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
    return "pending";
  }
}

/**
 * Settles a pending trial, then records its start (when a write is the one
 * that shows it), conversion and cancellation. Returns the subscription's
 * plan after settling. Best effort: never fails the write that triggered it.
 */
export async function applyTrialLifecycle(
  write: Pick<AppleSubscriptionWrite, "previous" | "current" | "applied">,
  notification: { readonly type: string | null; readonly subtype: string | null } | null,
  deps: TrialLifecycleDependencies,
): Promise<string> {
  const { current } = write;
  if (!write.applied) return current.planId;
  try {
    const settled = await settleTrialDevice(current, deps);
    if (settled !== "skipped") {
      return settled === "granted" ? "go" : settled === "pending" ? "trial_pending" : "trial_unverified";
    }
    const event = trialTransition(write.previous, current, notification);
    if (event) await captureTrialEvent(event, current, deps);
  } catch (error) {
    console.warn("billing.trial.lifecycle_failed", {
      originalTransactionId: current.originalTransactionId,
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
  }
  return current.planId;
}

/** Cron: retries trials whose device check did not finish. */
export async function settlePendingTrials(deps: TrialLifecycleDependencies, limit = 50): Promise<Record<TrialSettlement, number>> {
  const counts: Record<TrialSettlement, number> = { granted: 0, device_reused: 0, unverified: 0, pending: 0, skipped: 0 };
  for (const row of await deps.store.pendingTrialSubscriptions(limit)) {
    counts[await settleTrialDevice(row, deps)] += 1;
  }
  return counts;
}

/** The trial the account-token offers, or why not. */
export type TrialOffer = {
  readonly offered: true;
  readonly planId: "pro";
  readonly billingPeriod: "monthly";
  readonly productId: string;
  readonly attestRequired: true;
  readonly limits: typeof TRIAL_LIMITS;
};

export function trialOffer(): TrialOffer {
  return {
    offered: true,
    planId: "pro",
    billingPeriod: "monthly",
    productId: appleTrialProductId(TRIAL_BUNDLE_ID),
    attestRequired: true,
    limits: TRIAL_LIMITS,
  };
}

/** The variant that offers the trial, for account checks. */
export async function isTrialArm(userId: string): Promise<boolean> {
  return await servedPaywallVariant(userId, IOS_PAYWALL_EXPERIMENT) === TRIAL_PAYWALL_VARIANT;
}
