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
