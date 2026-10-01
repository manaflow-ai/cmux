import type { Metadata } from "next";
import Link from "next/link";
import { headers } from "next/headers";

import { preferredLocaleFromAcceptLanguage } from "../../../i18n/accept-language";
import { loadMessages } from "../../../i18n/messages";
import type { Locale } from "../../../i18n/routing";

type AuthErrorMessageKey = "emailUnverified" | "signupPending" | "generic";

type AuthErrorMessages = {
  emailUnverifiedTitle: string;
  emailUnverifiedBody: string;
  signupPendingBody: string;
  genericTitle: string;
  genericBody: string;
  backToSignIn: string;
};

type AuthErrorPageProps = {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

/** Keeps the recovery page out of search while using its localized title. */
export async function generateMetadata({
  searchParams,
}: AuthErrorPageProps): Promise<Metadata> {
  const [params, localized] = await Promise.all([
    searchParams,
    authErrorMessages(await headers()),
  ]);
  const key = authErrorMessageKey(firstParam(params.code));
  return {
    title: authErrorTitle(localized.messages, key),
    robots: { index: false, follow: false },
  };
}

/** Renders sanitized, localized recovery guidance for browser auth failures. */
export default async function AuthErrorPage({
  searchParams,
}: AuthErrorPageProps) {
  const [params, localized] = await Promise.all([
    searchParams,
    authErrorMessages(await headers()),
  ]);
  const key = authErrorMessageKey(firstParam(params.code));
  const { locale, messages } = localized;
  const signInHref = signInHrefForParams(params);
  const direction = locale === "ar" ? "rtl" : "ltr";

  return (
    <main
      className="flex min-h-screen items-center justify-center bg-background px-4 py-12 text-foreground"
      dir={direction}
    >
      <section
        className="w-full max-w-[340px]"
        data-auth-error={key}
        lang={locale}
      >
        <h1 className="text-[22px] font-semibold tracking-[-0.02em]">
          {authErrorTitle(messages, key)}
        </h1>
        <p className="mt-1.5 mb-6 text-sm leading-6 text-muted">
          {key === "emailUnverified"
            ? messages.emailUnverifiedBody
            : key === "signupPending"
              ? messages.signupPendingBody
              : messages.genericBody}
        </p>
        <Link
          className="flex h-[38px] w-full cursor-pointer items-center justify-center border border-foreground bg-foreground px-3 text-sm font-medium text-background transition-opacity hover:opacity-85 active:opacity-75 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          href={signInHref}
        >
          {messages.backToSignIn}
        </Link>
      </section>
    </main>
  );
}

/** Maps an external query token onto the closed set of product-owned states. */
function authErrorMessageKey(code: string | null): AuthErrorMessageKey {
  if (code === "signup-pending") return "signupPending";
  return code === "email-conflict" || code === "email-unverified"
    ? "emailUnverified"
    : "generic";
}

/** Loads the complete locale-specific auth error catalog for this request. */
async function authErrorMessages(headersList: Headers): Promise<{
  locale: Locale;
  messages: AuthErrorMessages;
}> {
  const locale = preferredLocaleFromAcceptLanguage(
    headersList.get("accept-language") ?? "",
  );
  const catalog = await loadMessages(locale);
  return {
    locale,
    messages: catalog.authError as AuthErrorMessages,
  };
}

/** Selects the safe page title without interpolating upstream error data. */
function authErrorTitle(
  messages: AuthErrorMessages,
  key: AuthErrorMessageKey,
): string {
  return key === "emailUnverified" || key === "signupPending"
    ? messages.emailUnverifiedTitle
    : messages.genericTitle;
}

/** Reads the first query value when Next represents a repeated parameter. */
function firstParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}

/** Preserves the signed-in handoff target when a user returns to sign-in. */
function signInHrefForParams(
  params: Record<string, string | string[] | undefined>,
): string {
  const query = new URLSearchParams();
  for (const name of [
    "after_auth_return_to",
    "web_return_to",
    "native_app_return_to",
  ]) {
    const value = firstParam(params[name]);
    if (value) query.set(name, value);
  }
  const serialized = query.toString();
  return serialized ? `/handler/sign-in?${serialized}` : "/handler/sign-in";
}
