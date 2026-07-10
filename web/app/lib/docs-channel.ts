export type DocsChannel = "release" | "nightly";

const productionOrigin = "https://cmux.com";

export function docsChannel(): DocsChannel {
  return process.env.CMUX_DOCS_CHANNEL === "nightly" ? "nightly" : "release";
}

export function releaseDocsOrigin(): string {
  return process.env.CMUX_RELEASE_DOCS_ORIGIN ?? productionOrigin;
}

export function nightlyDocsOrigin(): string {
  return process.env.CMUX_NIGHTLY_DOCS_ORIGIN ?? "https://nightly-docs.cmux.com";
}

export function docsCanonicalOrigin(): string {
  // Nightly is useful to people testing main, but release docs own search results.
  return releaseDocsOrigin();
}

export function docsChannelUrl(
  origin: string,
  pathname: string,
  search = "",
  hash = "",
): string {
  return new URL(`${pathname}${search}${hash}`, origin).toString();
}
