import type { Locale } from "../../../i18n/routing";
import { locales, routing } from "../../../i18n/routing";

export type SignInChooserMessages = {
  title: string;
  continueProduct: string;
  continueAction: string;
  useAnotherAccount: string;
  loading: string;
  signInFailed: string;
  privacyPrefix: string;
  privacyPolicy: string;
  privacyMiddle: string;
  termsOfService: string;
};

export type LocalizedSignInChooserMessages = {
  locale: Locale;
  messages: SignInChooserMessages;
};

export function preferredHandlerLocale(accepted: string | null): Locale {
  const requested = (accepted ?? "")
    .split(",")
    .map((part) => part.split(";")[0]?.trim())
    .filter(Boolean);
  for (const language of requested) {
    const exact = locales.find(
      (locale) => locale.toLowerCase() === language.toLowerCase(),
    );
    if (exact) return exact;
    const base = language.split("-")[0]?.toLowerCase();
    const baseMatch = locales.find(
      (locale) => locale.toLowerCase().split("-")[0] === base,
    );
    if (baseMatch) return baseMatch;
  }
  return routing.defaultLocale;
}

export async function signInChooserMessages(
  accepted: string | null,
): Promise<LocalizedSignInChooserMessages> {
  const locale = preferredHandlerLocale(accepted);
  const messages = (await import(`../../../messages/${locale}.json`))
    .default as {
    signInChooser?: SignInChooserMessages;
  };
  if (!messages.signInChooser) {
    throw new Error(`Missing signInChooser messages for locale ${locale}`);
  }
  return { locale, messages: messages.signInChooser };
}
