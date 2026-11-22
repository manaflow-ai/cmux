export type DocsChannel = "release" | "nightly";

const productionOrigin = "https://cmux.com";
const defaultReleaseDocsOrigin = "https://cmux-docs-release.vercel.app";
const defaultNightlyDocsOrigin = "https://cmux-docs-nightly.vercel.app";
const docsPathnamePattern = /^\/(?:[a-z]{2}(?:-[A-Z]{2})?\/)?docs(?:\/|$)/u;

/**
 * The deployment that serves cmux.com/docs. The main site rewrites every docs
 * path there, and it is built from the latest release tag, not from main.
 */
export function releaseDocsOrigin(
  env: Readonly<Record<string, string | undefined>> = process.env,
): string {
  return env.CMUX_RELEASE_DOCS_ORIGIN ?? defaultReleaseDocsOrigin;
}

/** The deployment that serves cmux.com/docs/nightly, built from main. */
export function nightlyDocsOrigin(
  env: Readonly<Record<string, string | undefined>> = process.env,
): string {
  return env.CMUX_NIGHTLY_DOCS_ORIGIN ?? defaultNightlyDocsOrigin;
}

/** Whether a deployment is a docs zone rather than the main site. */
export function isDocsZoneDeployment(
  env: Readonly<Record<string, string | undefined>> = process.env,
): boolean {
  return env.CMUX_DOCS_CHANNEL === "release" || env.CMUX_DOCS_CHANNEL === "nightly";
}

/** Whether a pathname, with or without a locale prefix, is a docs path. */
export function isDocsPathname(pathname: string): boolean {
  return docsPathnamePattern.test(pathname);
}

export function docsChannel(): DocsChannel {
  return process.env.CMUX_DOCS_CHANNEL === "nightly" ? "nightly" : "release";
}

export function docsCanonicalOrigin(): string {
  return productionOrigin;
}

export function docsPathAvailableInChannel(
  channel: DocsChannel,
  pathname: string,
): boolean {
  const releasePath = pathname.replace(/\/docs\/nightly(?=\/|$)/, "/docs");
  return channel === "nightly" || !/\/docs\/base(?=\/|$)/.test(releasePath);
}

export function docsChannelUrl(
  channel: DocsChannel,
  pathname: string,
  search = "",
  hash = "",
): string {
  const releasePath = pathname.replace(/\/docs\/nightly(?=\/|$)/, "/docs");
  const releaseFallback = docsPathAvailableInChannel("release", releasePath)
    ? releasePath
    : releasePath.replace(/\/docs\/base(?=\/|$)/, "/docs/getting-started");
  const targetPath = channel === "nightly"
    ? releasePath.replace(/\/docs(?=\/|$)/, "/docs/nightly")
    : releaseFallback;
  return `${targetPath}${search}${hash}`;
}

export function docsNavPath(pathname: string, locale: string): string {
  const releasePath = docsChannelUrl("release", pathname);
  const localePrefix = `/${locale}`;
  return releasePath.startsWith(`${localePrefix}/`)
    ? releasePath.slice(localePrefix.length)
    : releasePath;
}
