export type DocsChannel = "release" | "nightly";

const productionOrigin = "https://cmux.com";

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
