import { createTranslator } from "use-intl/core";
import { preferredLocaleFromAcceptLanguage } from "../../i18n/accept-language";
import { loadMessages } from "../../i18n/messages";
import { routing, type Locale } from "../../i18n/routing";

/** Copy returned for a provider operation that is permanently unavailable. */
export type VmUnsupportedCopy = {
  readonly title: string;
  readonly reason: string;
  readonly message: string;
  readonly action: string;
};

/**
 * Select the locale for a VM API response. Native clients may send the
 * middleware locale header; browser requests use the URL/referrer or the
 * standard Accept-Language negotiation.
 */
export function vmRequestLocale(request: Request): Locale {
  const headerLocale = localeFromValue(request.headers.get("x-next-intl-locale"));
  if (headerLocale) return headerLocale;

  const urlLocale = localeFromPath(request.url);
  if (urlLocale) return urlLocale;

  const referer = request.headers.get("referer");
  if (referer) {
    const refererLocale = localeFromPath(referer);
    if (refererLocale) return refererLocale;
  }

  const cookieLocale = localeFromCookie(request.headers.get("cookie"));
  if (cookieLocale) return cookieLocale;

  return preferredLocaleFromAcceptLanguage(request.headers.get("accept-language") ?? "");
}

/** Load and translate the phase-specific unsupported-operation response copy. */
export type VmUnsupportedOperationKey =
  | "snapshot"
  | "restore"
  | "fork"
  | "openPort"
  | "sizing"
  | "persistentHome"
  | "pause"
  | "resume"
  | "default";

/** Maps a workflow operation to the stable copy key used by the API response. */
export function vmUnsupportedOperationKey(operation: string): VmUnsupportedOperationKey {
  const normalized = operation.toLowerCase();
  if (normalized.includes("openport") || normalized.includes("open_port")) return "openPort";
  if (normalized.includes("restore")) return "restore";
  if (normalized.includes("fork")) return "fork";
  if (normalized.includes("snapshot")) return "snapshot";
  // `cmux vm pause` / `cmux vm resume`: a provider without the verb answers a
  // pause-specific 501, so the CLI can say "this provider cannot pause machines".
  if (normalized.includes("pause")) return "pause";
  if (normalized.includes("resume")) return "resume";
  return "default";
}

export async function vmUnsupportedCopy(
  phase: VmUnsupportedOperationKey,
  locale: Locale,
): Promise<VmUnsupportedCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.unsupported",
  }) as unknown as (key: string) => string;
  const phaseKey: VmUnsupportedOperationKey = ["snapshot", "restore", "fork", "openPort", "sizing", "persistentHome", "pause", "resume"].includes(phase)
    ? phase
    : "default";
  return {
    title: translator("title"),
    reason: translator("reason"),
    message: translator(`message.${phaseKey}`),
    action: translator(`action.${phaseKey}`),
  };
}

/** Copy returned when a provisioning verb is blocked by the paid-plan gate. */
export type VmRequiresProCopy = {
  readonly title: string;
  readonly message: string;
  readonly action: string;
};

/** Localized setup guidance for unavailable runtime artifacts, without operator diagnostics. */
export async function vmArtifactUnavailableCopy(locale: Locale): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.artifactUnavailable",
  }) as unknown as (key: string) => string;
  return {
    title: translator("title"),
    message: translator("message"),
    action: translator("action"),
  };
}

/** Localized guidance for a machine that must be recreated before it can be attached. */
export async function vmRecreateRequiredCopy(locale: Locale): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.recreateRequired",
  }) as unknown as (key: string) => string;
  return {
    title: translator("title"),
    message: translator("message"),
    action: translator("action"),
  };
}

/** Localized guidance for a machine whose guest stopped answering provider commands. */
export async function vmGuestUnresponsiveCopy(locale: Locale): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.guestUnresponsive",
  }) as unknown as (key: string) => string;
  return {
    title: translator("title"),
    message: translator("message"),
    action: translator("action"),
  };
}

/** Localized copy for a read that answered at its deadline (routeDeadline.ts). */
export async function vmProviderTimeoutCopy(locale: Locale): Promise<VmRequiresProCopy> {
  return vmRouteDeadlineCopy("providerTimeout", locale);
}

/** Localized copy for a VM route that answered at its deadline (routeDeadline.ts). */
export async function vmRouteDeadlineCopy(kind: "inProgress" | "providerTimeout", locale: Locale): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: `vmErrors.${kind}`,
  }) as unknown as (key: string) => string;
  return {
    title: translator("title"),
    message: translator("message"),
    action: translator("action"),
  };
}

/** Localized copy for a provider capacity refusal (routeHelpers vmProviderCapacityResponse). */
export async function vmProviderCapacityCopy(locale: Locale): Promise<VmRequiresProCopy> {
  return vmErrorsCopy("providerCapacity", locale);
}

/** Localized copy for a machine-state conflict (routeHelpers vmStateConflictResponse). */
export async function vmStateConflictCopy(locale: Locale): Promise<VmRequiresProCopy> {
  return vmErrorsCopy("stateConflict", locale);
}

async function vmErrorsCopy(key: "providerCapacity" | "stateConflict", locale: Locale): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: `vmErrors.${key}`,
  }) as unknown as (key: string) => string;
  return {
    title: translator("title"),
    message: translator("message"),
    action: translator("action"),
  };
}

/** Localized copy for admission and snapshot guards added before provider work. */
export async function vmMutationGuardCopy(
  key:
    | "allocationUnavailable"
    | "snapshotIdempotencyRequired"
    | "snapshotInProgress"
    | "snapshotIdempotencyConflict"
    | "snapshotQuota",
  locale: Locale,
): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: `vmErrors.${key}`,
  }) as unknown as (key: string) => string;
  return {
    title: translator("title"),
    message: translator("message"),
    action: translator("action"),
  };
}

/** Localized guidance when the provider account's network rule capacity is exhausted. */
export async function vmNetworkRuleCapacityCopy(locale: Locale): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.networkRuleCapacity",
  }) as unknown as (key: string) => string;
  return {
    title: translator("title"),
    message: translator("message"),
    action: translator("action"),
  };
}

/** Localized copy for a stored network policy apply failure code. */
export async function vmNetworkPolicyStatusMessage(
  code: "network_rule_capacity" | "apply_failed",
  locale: Locale,
): Promise<string> {
  if (code === "network_rule_capacity") {
    const copy = await vmNetworkRuleCapacityCopy(locale);
    return `${copy.message} ${copy.action}`;
  }
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.networkPolicyStatus",
  }) as unknown as (key: string) => string;
  return translator("applyFailed");
}

/** Localized, user-safe guidance when guest Cloud VM setup does not complete. */
export type VmGuestInstallCopy = VmRequiresProCopy & { readonly reason: string };
export async function vmGuestInstallCopy(locale: Locale): Promise<VmGuestInstallCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.guestInstall",
  }) as unknown as (key: string) => string;
  return {
    title: translator("title"),
    reason: translator("reason"),
    message: translator("message"),
    action: translator("action"),
  };
}

export async function vmCreateCleanupPendingCopy(locale: Locale): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.createCleanupPending",
  }) as unknown as (key: string) => string;
  return { title: translator("title"), message: translator("message"), action: translator("action") };
}

/** Load and translate the `vm_requires_pro` response copy for the request locale. */
export async function vmRequiresProCopy(
  locale: Locale,
  values: { readonly upgradeUrl: string; readonly planId: string },
): Promise<VmRequiresProCopy> {
  const messages = await loadMessages(locale);
  const translator = createTranslator({
    locale,
    messages,
    namespace: "vmErrors.requiresPro",
  }) as unknown as (key: string, values?: Record<string, string>) => string;
  const planTranslator = createTranslator({
    locale,
    messages,
    namespace: "pricing",
  }) as unknown as (key: string) => string;
  const plan = planTranslator(`${values.planId}.name`);
  return {
    title: translator("title", { plan }),
    message: translator("message", { plan }),
    action: translator("action", { plan, upgradeUrl: values.upgradeUrl }),
  };
}

/** Copy returned when a create or rename carries an unusable `displayName`. */
export async function vmDisplayNameCopy(
  locale: Locale,
  values: { readonly maxLength: number },
): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.displayName",
  }) as unknown as (key: string, values?: Record<string, string | number>) => string;
  return {
    title: translator("title"),
    message: translator("message", values),
    action: translator("action"),
  };
}

export async function vmMemoryErrorCopy(
  kind: "memoryPlan" | "memoryUnknown" | "memoryUnavailable",
  locale: Locale,
  values: Record<string, string | number> = {},
): Promise<VmRequiresProCopy> {
  const t = createTranslator({ locale, messages: await loadMessages(locale), namespace: `vmErrors.${kind}` }) as unknown as (key: string, values?: Record<string, string | number>) => string;
  return { title: kind === "memoryPlan" ? t("title", values) : t("message", values),
    message: t("message", values), action: t("action", values) };
}

/** Localized copy for the Go plan's hard limits. */
export async function vmGoLimitCopy(
  kind: "saved" | "active" | "hours" | "shape",
  locale: Locale,
): Promise<{ readonly message: string; readonly action: string }> {
  const t = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.goLimit",
  }) as unknown as (key: string) => string;
  return { message: t(`${kind}Message`), action: t(`${kind}Action`) };
}

/**
 * Localized copy for a used-up Pro or Max allowance. The reset date is the
 * end of the billing period, shown as a UTC calendar date.
 */
export async function vmPlanBudgetCopy(
  locale: Locale,
  values: {
    readonly resource: "compute" | "storage";
    readonly planId: "pro" | "max";
    readonly included: number;
    readonly used: number;
    readonly requested: number;
    readonly resetsAt: Date;
  },
): Promise<VmRequiresProCopy> {
  const t = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.planBudget",
  }) as unknown as (key: string, values?: Record<string, string | number>) => string;
  const resetDate = new Intl.DateTimeFormat(locale, { dateStyle: "long", timeZone: "UTC" }).format(values.resetsAt);
  const plan = values.planId === "max" ? "Max" : "Pro";
  const args = { plan, included: values.included, used: values.used, requested: values.requested, resetDate };
  const upgrade = values.planId === "pro" ? "Upgrade" : "";
  return {
    title: t(`${values.resource}Title`, args),
    message: t(`${values.resource}Message`, args),
    action: t(`${values.resource}Action${upgrade}`, args),
  };
}

/**
 * The localized sentence naming the machines an active-VM limit counted, or
 * "" when there are none. It is appended to the plan sentence, so it starts
 * with a space.
 */
export async function vmActiveLimitCountedCopy(
  locale: Locale,
  machines: readonly { readonly name: string; readonly status: "provisioning" | "running" }[],
): Promise<string> {
  if (machines.length === 0) return "";
  const t = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.activeLimit",
  }) as unknown as (key: string, values?: Record<string, string>) => string;
  const names = machines.map((machine) =>
    machine.status === "provisioning" ? t("provisioning", { name: machine.name }) : machine.name
  );
  return ` ${t("counted", { machines: names.join(t("separator")) })}`;
}

/** Localized copy for a create, resume, resize, or fork that does not fit the shared pool. */
export async function vmResourcePoolCopy(
  locale: Locale,
  values: {
    readonly resource: "memoryMb" | "vcpus";
    readonly used: number;
    readonly pool: number;
    readonly requested: number;
    readonly canUpgrade: boolean;
  },
): Promise<VmRequiresProCopy> {
  const t = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.resourcePool",
  }) as unknown as (key: string, values?: Record<string, string | number>) => string;
  const numbers = { used: values.used, pool: values.pool, requested: values.requested };
  return {
    title: t("title"),
    message: t(values.resource === "memoryMb" ? "memoryMessage" : "vcpuMessage", numbers),
    action: t(values.canUpgrade ? "upgradeAction" : "action"),
  };
}

function localeFromPath(value: string): Locale | null {
  try {
    const firstSegment = new URL(value).pathname.split("/").filter(Boolean)[0];
    return localeFromValue(firstSegment);
  } catch {
    return null;
  }
}

function localeFromCookie(value: string | null): Locale | null {
  if (!value) return null;
  const localeCookie = value
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith("NEXT_LOCALE="));
  return localeFromValue(localeCookie?.slice("NEXT_LOCALE=".length));
}

function localeFromValue(value: string | null | undefined): Locale | null {
  const normalized = value?.trim().toLowerCase();
  if (!normalized) return null;
  return routing.locales.find((locale) => locale.toLowerCase() === normalized) ?? null;
}
