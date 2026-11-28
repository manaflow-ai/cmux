export function headersForCanonicalFetch({
  requestHeaders,
  searchParams,
}: {
  requestHeaders: Headers;
  searchParams: URLSearchParams;
}): Headers {
  const headers = new Headers({
    accept: "text/html",
    "x-cmux-agent-page-variant": "canonical-html",
  });

  copyRequestHeader(requestHeaders, headers, "authorization");
  copyRequestHeader(requestHeaders, headers, "cookie");
  copyRequestHeader(requestHeaders, headers, "accept-language");

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
