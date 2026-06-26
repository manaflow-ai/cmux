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

export const dynamic = "force-dynamic";

type LocalizedAfterSignInMessages = {
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

function returnPage(href: string, localized: LocalizedAfterSignInMessages): NextResponse {
  const { locale, messages } = localized;
  const label = nativeReturnLabel(href, messages);
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

export async function GET(request: NextRequest) {
  const nativeReturnTo = request.nextUrl.searchParams.get("native_app_return_to");
  if (!nativeReturnTo) return NextResponse.redirect(new URL("/", request.url));
  if (!isMobileNativeReturnTo(nativeReturnTo) || !isAllowedNativeReturnTo(nativeReturnTo, request)) {
    return NextResponse.redirect(new URL("/", request.url));
  }

  const href = buildMobileNativeErrorHref(nativeReturnTo);
  if (!href) return NextResponse.redirect(new URL("/", request.url));
  return returnPage(href, await mobileMagicLinkMessages(request));
}
