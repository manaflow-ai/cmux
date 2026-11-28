export function sameOriginRedirectUrl({
  currentUrl,
  location,
  origin,
}: {
  currentUrl: URL;
  location: string | null;
  origin: string;
}): URL | null {
  if (!location) {
    return null;
  }

  try {
    const nextUrl = new URL(location, currentUrl);
    if (nextUrl.origin !== origin) {
      return null;
    }
    nextUrl.hash = "";
    return nextUrl;
  } catch {
    return null;
  }
}
