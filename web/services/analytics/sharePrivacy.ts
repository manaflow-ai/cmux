const SHARE_PATH_PATTERN =
  /(?:^|\/)share\/[A-Za-z0-9]{8,64}(?:\/|$)/u;

/** Static browser privacy policy for every authenticated share page. */
export const privateSharePageMetadata = {
  referrer: "no-referrer",
  robots: { index: false, follow: false },
} as const;

/**
 * Share codes are invitation credentials. They must never enter page-view,
 * page-leave, autocapture, or referrer analytics.
 */
export function containsPrivateSharePath(value: string): boolean {
  try {
    return SHARE_PATH_PATTERN.test(
      new URL(value, "https://cmux.invalid").pathname,
    );
  } catch {
    return SHARE_PATH_PATTERN.test(value.split(/[?#]/u, 1)[0] ?? "");
  }
}

/** Direct share-page loads do not initialize the analytics client at all. */
export function shouldInitializeAnalytics(pathname: string): boolean {
  return !containsPrivateSharePath(pathname);
}

/** Drop an event when any top-level string property contains a share URL. */
export function analyticsPropertiesContainSharePath(
  properties: Readonly<Record<string, unknown>>,
): boolean {
  return Object.values(properties).some(
    (value) =>
      typeof value === "string" && containsPrivateSharePath(value),
  );
}
