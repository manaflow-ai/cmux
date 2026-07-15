export type DocsChannel = "release" | "nightly";

const productionOrigin = "https://cmux.com";

export function docsChannel(): DocsChannel {
  return process.env.CMUX_DOCS_CHANNEL === "nightly" ? "nightly" : "release";
}

export function docsCanonicalOrigin(): string {
  return productionOrigin;
}

export function docsChannelUrl(
  channel: DocsChannel,
  pathname: string,
  search = "",
  hash = "",
): string {
  const releasePath = pathname.replace(/\/docs\/nightly(?=\/|$)/, "/docs");
  const targetPath = channel === "nightly"
    ? releasePath.replace(/\/docs(?=\/|$)/, "/docs/nightly")
    : releasePath;
  return `${targetPath}${search}${hash}`;
}
