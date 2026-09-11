import type { Metadata } from "next";
import Link from "next/link";
import { headers } from "next/headers";

import { preferredLocaleFromAcceptLanguage } from "../../../i18n/accept-language";
import { loadMessages } from "../../../i18n/messages";
import type { Locale } from "../../../i18n/routing";

type AuthErrorMessageKey = "emailUnverified" | "generic";

type AuthErrorMessages = {
  emailUnverifiedTitle: string;
  emailUnverifiedBody: string;
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
      className="flex min-h-screen items-center justify-center bg-[#faf9f6] px-6 text-[#25231f]"
      dir={direction}
    >
      <section
        className="w-full max-w-md border border-[#ded9cf] bg-white p-7 shadow-[4px_4px_0_#eee8dc]"
        data-auth-error={key}
        lang={locale}
      >
        <p className="mb-2 font-mono text-xs lowercase tracking-[0.16em] text-[#9a5b22]">
          cmux
        </p>
        <h1 className="mb-3 text-xl font-medium">
          {authErrorTitle(messages, key)}
        </h1>
        <p className="mb-6 text-sm leading-6 text-[#6f6a61]">
          {key === "emailUnverified"
            ? messages.emailUnverifiedBody
            : messages.genericBody}
        </p>
        <Link
          className="inline-flex min-h-10 items-center justify-center bg-[#25231f] px-4 py-2 text-sm font-medium text-white hover:bg-[#3a3731]"
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
  return key === "emailUnverified"
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
