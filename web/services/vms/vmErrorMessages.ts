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
export async function vmUnsupportedCopy(
  phase: "snapshot" | "restore" | "fork" | "default",
  locale: Locale,
): Promise<VmUnsupportedCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.unsupported",
  }) as unknown as (key: string) => string;
  const phaseKey = phase === "snapshot" || phase === "restore" || phase === "fork"
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

/** Load and translate the `vm_requires_pro` response copy for the request locale. */
export async function vmRequiresProCopy(
  locale: Locale,
  values: { readonly upgradeUrl: string },
): Promise<VmRequiresProCopy> {
  const translator = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmErrors.requiresPro",
  }) as unknown as (key: string, values?: Record<string, string>) => string;
  return {
    title: translator("title"),
    message: translator("message"),
    action: translator("action", { upgradeUrl: values.upgradeUrl }),
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
