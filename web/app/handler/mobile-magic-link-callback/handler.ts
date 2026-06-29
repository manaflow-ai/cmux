import { NextRequest, NextResponse } from "next/server";
import {
  type AfterSignInMessages,
  buildMobileNativeErrorHref,
  isAllowedNativeReturnTo,
  isMobileNativeReturnTo,
  nativeReturnLabel,
} from "../after-sign-in/native-return";
import type { Locale } from "../../../i18n/routing";
import { locales, routing } from "../../../i18n/routing";

type LocalizedAfterSignInMessages = {
  locale: Locale;
  messages: AfterSignInMessages;
};

export type MobileMagicLinkCallbackModel = {
  href: string;
  label: string;
  locale: Locale;
  messages: AfterSignInMessages;
};

function preferredLocale(request: NextRequest): Locale {
  const accepted = request.headers.get("accept-language") ?? "";
  const requested = accepted
    .split(",")
    .map((part) => part.split(";")[0]?.trim())
    .filter(Boolean);
  for (const language of requested) {
    const exact = locales.find((locale) => locale.toLowerCase() === language.toLowerCase());
    if (exact) return exact;
    const base = language.split("-")[0]?.toLowerCase();
    const baseMatch = locales.find((locale) => locale.toLowerCase().split("-")[0] === base);
    if (baseMatch) return baseMatch;
  }
  return routing.defaultLocale;
}

async function mobileMagicLinkMessages(request: NextRequest): Promise<LocalizedAfterSignInMessages> {
  const locale = preferredLocale(request);
  const messages = (await import(`../../../messages/${locale}.json`)).default as {
    mobileMagicLinkCallback?: AfterSignInMessages;
  };
  if (!messages.mobileMagicLinkCallback) {
    throw new Error(`Missing mobileMagicLinkCallback messages for locale ${locale}`);
  }
  return { locale, messages: messages.mobileMagicLinkCallback };
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function returnPage(model: MobileMagicLinkCallbackModel): NextResponse {
  const { href, label, locale, messages } = model;
  const escapedHref = escapeHtml(href);
  const escapedLabel = escapeHtml(label);
  const escapedTitle = escapeHtml(messages.title);
  const escapedBody = escapeHtml(messages.body);
  const scriptHref = JSON.stringify(href).replaceAll("<", "\\u003c");
  return new NextResponse(
    `<!doctype html>
<html lang="${escapeHtml(locale)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapedTitle}</title>
  <script>window.location.replace(${scriptHref});</script>
</head>
<body>
  <main>
    <h1>${escapedTitle}</h1>
    <p>${escapedBody}</p>
    <a href="${escapedHref}">${escapedLabel}</a>
  </main>
</body>
</html>`,
    {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
      },
    }
  );
}

export async function mobileMagicLinkCallbackModel(
  request: NextRequest
): Promise<MobileMagicLinkCallbackModel | null> {
  const nativeReturnTo = request.nextUrl.searchParams.get("native_app_return_to");
  if (!nativeReturnTo) return null;
  if (!isMobileNativeReturnTo(nativeReturnTo) || !isAllowedNativeReturnTo(nativeReturnTo, request)) {
    return null;
  }

  const href = buildMobileNativeErrorHref(nativeReturnTo);
  if (!href) return null;
  const localized = await mobileMagicLinkMessages(request);
  return {
    href,
    label: nativeReturnLabel(href, localized.messages),
    locale: localized.locale,
    messages: localized.messages,
  };
}

export async function mobileMagicLinkCallbackResponse(request: NextRequest) {
  const model = await mobileMagicLinkCallbackModel(request);
  if (!model) return NextResponse.redirect(new URL("/", request.url));
  return returnPage(model);
}
