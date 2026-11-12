export function headersForCanonicalFetch({
  requestHeaders,
  searchParams,
  englishOnly = false,
}: {
  requestHeaders: Headers;
  searchParams: URLSearchParams;
  /**
   * The page exists only in English: ask for English whatever the reader's
   * Accept-Language or NEXT_LOCALE cookie says, so locale negotiation cannot
   * pick a localized route the page does not have.
   */
  englishOnly?: boolean;
}): Headers {
  const headers = new Headers({
    accept: "text/html",
    "x-cmux-agent-page-variant": "canonical-html",
  });

  copyRequestHeader(requestHeaders, headers, "authorization");
  if (englishOnly) {
    const cookie = englishLocaleCookie(requestHeaders.get("cookie"));
    if (cookie) headers.set("cookie", cookie);
    headers.set("accept-language", "en");
  } else {
    copyRequestHeader(requestHeaders, headers, "cookie");
    copyRequestHeader(requestHeaders, headers, "accept-language");
  }

  const protectionBypass =
    requestHeaders.get("x-vercel-protection-bypass") ??
    searchParams.get("x-vercel-protection-bypass");
  if (protectionBypass) {
    headers.set("x-vercel-protection-bypass", protectionBypass);
  }

  const setBypassCookie =
    requestHeaders.get("x-vercel-set-bypass-cookie") ??
    searchParams.get("x-vercel-set-bypass-cookie");
  if (setBypassCookie) {
    headers.set("x-vercel-set-bypass-cookie", setBypassCookie);
  }

  return headers;
}

export function hasSensitiveCanonicalAccess(headers: Headers): boolean {
  return (
    headers.has("authorization") ||
    headers.has("cookie") ||
    headers.has("x-vercel-protection-bypass") ||
    headers.has("x-vercel-set-bypass-cookie")
  );
}

/** The cookie header with next-intl's NEXT_LOCALE set to English (when present). */
function englishLocaleCookie(cookie: string | null): string | null {
  if (!cookie) return null;
  return cookie
    .split(";")
    .map((part) => (/^\s*NEXT_LOCALE=/u.test(part) ? part.replace(/=.*$/u, "=en") : part))
    .join(";");
}

function copyRequestHeader(
  requestHeaders: Headers,
  headers: Headers,
  name: string,
) {
  const value = requestHeaders.get(name);
  if (value) {
    headers.set(name, value);
  }
}
