// Resolves the paywall the iOS app shows: control for everyone outside the
// `ios-paywall-v1` experiment, else the user's sticky variant from the
// PostHog multivariate flag, with copy from the flag payload after the
// validator passes it. Records the assignment (`paywall_assigned`); the
// exposure is the app's `ios_paywall_viewed` (see EXPERIMENTS.md).

import { isAdminUser } from "../../admin/access";
import { captureServerEvent, type ServerEventInput } from "../../analytics/serverEvents";
import { iosAnalyticsChannel } from "../../analytics/iosEventPolicy";
import { isSyntheticAccountEmail } from "../../analytics/syntheticAccounts";
import { PLAN_SPECS } from "./facts";
import {
  isPostHogFlagsResponseAvailable,
  normalizePostHogFlagsResponse,
  postHogFlagsBody,
  postHogFlagsUrl,
} from "../../client-config/posthogFlags";
import { captureBillingError } from "../../errors";
import {
  IOS_PAYWALL_CONTROL,
  IOS_PAYWALL_CONTROL_VARIANT,
  IOS_PAYWALL_EXPERIMENT,
} from "./iosPaywallV1";
import { databasePaywallAssignmentStore, type PaywallAssignmentStore } from "./store";
import {
  IOS_PAYWALL_BASE_LAYOUTS,
  IOS_PAYWALL_LAYOUTS,
  validateIosPaywallPayload,
  type IosPaywallConfig,
  type IosPaywallLayout,
} from "./validator";

const FLAG_TIMEOUT_MS = 1_500;

/** Server record of the variant served to a user; joined to the app's view event for exposure. */
export const PAYWALL_ASSIGNMENT_EVENT = "paywall_assigned";

/** The flag's answer for one person. */
export type PaywallFlagEvaluation =
  | { readonly state: "variant"; readonly variant: string; readonly payload: unknown }
  /** The flag is off or the person is outside its rollout: the kill switch. */
  | { readonly state: "off" }
  /** PostHog did not answer; sticky assignments are still served. */
  | { readonly state: "unavailable" };

export type IosPaywallUser = {
  readonly id: string;
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly isAnonymous?: boolean;
};

export type IosPaywallRequest = {
  /** The raw `x-cmux-bundle-id` header; no default, so only the App Store app says `production`. */
  readonly bundleIdHeader: string | null;
  /** The account can buy a plan in this app now (account-token `eligible` with products). */
  readonly purchasable: boolean;
  /** The account's current personal plan id. Only free accounts enter. */
  readonly currentPlanId: string;
  /** Layouts the app can draw (`x-cmux-paywall-layouts`); see requestedPaywallLayouts. */
  readonly supportedLayouts?: readonly IosPaywallLayout[];
  /** The account may be offered the trial now; `trialTimeline` is served only then. */
  readonly trialEligible?: boolean;
};

/**
 * `x-cmux-paywall-layouts: cards,comparison,focus,...`: the layouts this app
 * build can draw. An app that sends no header predates the header and knows
 * only the original three. Unknown names are ignored; `cards` is always in.
 */
export function requestedPaywallLayouts(header: string | null): readonly IosPaywallLayout[] {
  if (header === null) return IOS_PAYWALL_BASE_LAYOUTS;
  const named = new Set(header.split(",").map((value) => value.trim()));
  return IOS_PAYWALL_LAYOUTS.filter((layout) => layout === "cards" || named.has(layout));
}

/**
 * The config as this app receives it: a layout the app cannot draw, or a
 * trial layout for a user who cannot get the trial, becomes the variant's
 * fallback layout when that one can be drawn, else `cards`. The server-only
 * `fallbackLayout` is never sent.
 */
export function servedPaywallConfig(config: IosPaywallConfig, request: Pick<IosPaywallRequest, "supportedLayouts" | "trialEligible">): IosPaywallConfig {
  const supported = request.supportedLayouts ?? IOS_PAYWALL_BASE_LAYOUTS;
  const drawable = (layout: IosPaywallLayout | undefined) =>
    layout !== undefined && supported.includes(layout) && (layout !== "trialTimeline" || request.trialEligible === true);
  const layout = drawable(config.layout) ? config.layout : drawable(config.fallbackLayout) ? config.fallbackLayout! : "cards";
  const served: IosPaywallConfig = { ...config, layout, ...(layout === "specList" ? { planSpecs: PLAN_SPECS } : {}) };
  delete (served as { fallbackLayout?: IosPaywallLayout }).fallbackLayout;
  return served;
}

export type IosPaywallDependencies = {
  readonly evaluateFlag: (distinctId: string) => Promise<PaywallFlagEvaluation>;
  readonly store: PaywallAssignmentStore;
  readonly captureEvent: (input: ServerEventInput) => Promise<void>;
  readonly env: Record<string, string | undefined>;
  readonly now: () => Date;
  readonly reportInvalidPayload: (variant: string, errors: readonly string[]) => void;
};

/** Reads the flag through PostHog's `/flags` endpoint (no exposure is recorded by this call). */
export async function evaluatePaywallFlag(
  distinctId: string,
  flagKey: string = IOS_PAYWALL_EXPERIMENT,
  fetchImpl: typeof fetch = fetch,
): Promise<PaywallFlagEvaluation> {
  try {
    const response = await fetchImpl(postHogFlagsUrl(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: postHogFlagsBody(distinctId),
      cache: "no-store",
      signal: AbortSignal.timeout(FLAG_TIMEOUT_MS),
    });
    if (!response.ok) return { state: "unavailable" };
    const body = await response.json() as Record<string, unknown>;
    if (!isPostHogFlagsResponseAvailable(body)) return { state: "unavailable" };
    const config = normalizePostHogFlagsResponse(body);
    const value = config.featureFlags[flagKey];
    if (typeof value === "string") return { state: "variant", variant: value, payload: config.featureFlagPayloads[flagKey] };
    // A flag that failed to compute is absent; that is an outage, not "off".
    if (value === undefined && config.errorsWhileComputingFlags) return { state: "unavailable" };
    return { state: "off" };
  } catch {
    return { state: "unavailable" };
  }
}

const defaultDependencies = (): IosPaywallDependencies => ({
  evaluateFlag: (distinctId) => evaluatePaywallFlag(distinctId),
  store: databasePaywallAssignmentStore(),
  captureEvent: captureServerEvent,
  env: process.env,
  now: () => new Date(),
  reportInvalidPayload: (variant, errors) => {
    console.error("billing.paywall.invalid_payload", { experiment: IOS_PAYWALL_EXPERIMENT, variant, errors });
    captureBillingError(new Error(`Invalid ${IOS_PAYWALL_EXPERIMENT} payload for variant ${variant}`), {
      route: "paywall",
      experiment: IOS_PAYWALL_EXPERIMENT,
      variant,
    });
  },
});

function internalEmails(env: Record<string, string | undefined>): readonly string[] {
  return (env.PAYWALL_EXPERIMENT_INTERNAL_EMAILS ?? "")
    .split(",")
    .map((email) => email.trim().toLowerCase())
    .filter(Boolean);
}

/** Staff and allowlisted test accounts: they enter from any channel and are excluded from analysis. */
export function isPaywallInternalUser(user: IosPaywallUser, env: Record<string, string | undefined>): boolean {
  if (isAdminUser({ ...user, isAnonymous: user.isAnonymous ?? false })) return true;
  const email = user.primaryEmailVerified ? user.primaryEmail?.trim().toLowerCase() : null;
  return Boolean(email && internalEmails(env).includes(email));
}

type Enrollment = { readonly internal: boolean; readonly channel: string };

/** Who enters: the App Store app (or an internal account), on the free plan, able to buy. */
function enrollment(user: IosPaywallUser, request: IosPaywallRequest, env: Record<string, string | undefined>): Enrollment | null {
  if (!request.purchasable || request.currentPlanId !== "free") return null;
  if (isSyntheticAccountEmail(user.primaryEmail)) return null;
  const channel = iosAnalyticsChannel(request.bundleIdHeader?.trim() || null);
  const internal = isPaywallInternalUser(user, env);
  if (channel !== "production" && !internal) return null;
  return { internal, channel };
}

type Chosen = { readonly config: IosPaywallConfig; readonly sticky: boolean };

/**
 * The variant to serve. An assigned user always gets their stored variant
 * with the copy they were first shown, whatever the flag says now (unless it
 * is off): traffic moves and copy edits apply to new users only, so one arm
 * never mixes two versions of its copy. A new user gets the flag's variant.
 * A payload that fails validation is reported and never served.
 */
async function chooseVariant(
  userId: string,
  flag: PaywallFlagEvaluation,
  deps: IosPaywallDependencies,
): Promise<Chosen | null> {
  const stored = await deps.store.assignment(userId, IOS_PAYWALL_EXPERIMENT);
  if (stored) {
    const result = validateIosPaywallPayload(stored.payload, IOS_PAYWALL_EXPERIMENT, stored.variant);
    if (result.ok) return { config: result.value, sticky: flag.state !== "variant" || flag.variant !== stored.variant };
    deps.reportInvalidPayload(stored.variant, result.errors);
    return null;
  }
  if (flag.state !== "variant") return null;
  const result = validateIosPaywallPayload(flag.payload, IOS_PAYWALL_EXPERIMENT, flag.variant);
  if (result.ok) return { config: result.value, sticky: false };
  deps.reportInvalidPayload(flag.variant, result.errors);
  return null;
}

/**
 * The server's assignment record. Not an exposure: the app fetches the config
 * from the Settings plan row too. The exposure is the app's
 * `ios_paywall_viewed`, joined to this record by person (EXPERIMENTS.md).
 */
function assignmentEvent(
  userId: string,
  config: IosPaywallConfig,
  enrolled: Enrollment,
  sticky: boolean,
  now: Date,
  appLayouts: readonly IosPaywallLayout[],
): ServerEventInput {
  return {
    event: PAYWALL_ASSIGNMENT_EVENT,
    distinctId: userId,
    // One record per user, variant and UTC day.
    insertId: `paywall_assigned:${config.experiment}:${userId}:${config.variant}:${now.toISOString().slice(0, 10)}`,
    properties: {
      paywall_experiment: config.experiment,
      paywall_variant: config.variant,
      paywall_layout: config.layout,
      paywall_platform: "ios",
      paywall_channel: enrolled.channel,
      paywall_internal: enrolled.internal,
      paywall_sticky: sticky,
      // What this app can draw; the optimizer waits for adoption before promoting a newer layout.
      paywall_app_layouts: appLayouts.join(","),
    },
  };
}

/** The copy stored with an assignment: the payload without the flag-supplied keys. */
function storedPayload(config: IosPaywallConfig): Record<string, unknown> {
  const payload: Record<string, unknown> = { ...config };
  delete payload.experiment;
  delete payload.variant;
  return payload;
}

/**
 * The paywall for this user and app. Never throws: any failure serves
 * control without an exposure, so a broken experiment cannot break purchases.
 */
export async function resolveIosPaywall(
  user: IosPaywallUser,
  request: IosPaywallRequest,
  deps: IosPaywallDependencies = defaultDependencies(),
): Promise<IosPaywallConfig> {
  const control = servedPaywallConfig(IOS_PAYWALL_CONTROL, request);
  const enrolled = enrollment(user, request, deps.env);
  if (!enrolled) return control;
  try {
    const flag = await deps.evaluateFlag(user.id);
    // The kill switch wins over stickiness.
    if (flag.state === "off") return control;
    const chosen = await chooseVariant(user.id, flag, deps);
    if (!chosen) return control;
    // Assignment and copy are written once; later serves only touch served_at.
    await deps.store.recordServed(user.id, IOS_PAYWALL_EXPERIMENT, chosen.config.variant, storedPayload(chosen.config));
    const served = servedPaywallConfig(chosen.config, request);
    void deps.captureEvent(assignmentEvent(user.id, served, enrolled, chosen.sticky, deps.now(), request.supportedLayouts ?? IOS_PAYWALL_BASE_LAYOUTS));
    return served;
  } catch (error) {
    console.error("billing.paywall.resolve_failed", {
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
    return control;
  }
}

export { IOS_PAYWALL_CONTROL, IOS_PAYWALL_CONTROL_VARIANT, IOS_PAYWALL_EXPERIMENT };
