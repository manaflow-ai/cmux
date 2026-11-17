import type { Metadata } from "next";
import type { Listing } from "./registry";
import { SITE, authorPath, listingPath, listingUrl, repositoryTreeUrl, repositoryUrl } from "./refs";

/** The listing's one-line summary: tagline, else the description's first sentence. */
export function listingSummary(listing: Listing): string {
  if (listing.tagline) return listing.tagline;
  const first = listing.description.split(/(?<=[.!?])\s/u, 1)[0] ?? "";
  return first || `${listing.name} for cmux`;
}

const TIER_LABEL = { plugin: "cmux plugin", theme: "cmux theme", snippet: "cmux snippet", setup: "cmux setup" } as const;

export function listingTitle(listing: Listing): string {
  return `${listing.name}: ${TIER_LABEL[listing.tier]} by ${listing.publisher ?? listing.owner}`;
}

export function listingDescription(listing: Listing): string {
  const base = listing.description || listingSummary(listing);
  const full = `${base} Free, open source, installs into cmux for macOS in one click.`;
  return full.length <= 300 ? full : `${base.slice(0, 297).trimEnd()}...`;
}

/** The social card: the page's generated image (name, tagline, icon, screenshot). */
export function listingOpenGraphImage(listing: Listing): string {
  return `${SITE}/extensions/og.png?${new URLSearchParams({ kind: listing.kind, page: listingPath(listing, listing.kind) })}`;
}

export function listingMetadata(listing: Listing): Metadata {
  const title = listingTitle(listing);
  const description = listingDescription(listing);
  const url = listingUrl(listing, listing.kind);
  const image = listingOpenGraphImage(listing);
  return {
    title: { absolute: title },
    description,
    alternates: { canonical: url },
    openGraph: {
      siteName: "cmux",
      type: "website",
      title,
      description,
      url,
      images: [{ url: image, width: 1200, height: 630, alt: `${listing.name} for cmux` }],
    },
    twitter: { card: "summary_large_image", title, description, images: [image] },
  };
}

/** schema.org SoftwareApplication for a listing page. */
export function listingJsonLd(listing: Listing): Record<string, unknown> {
  const url = listingUrl(listing, listing.kind);
  const source = repositoryTreeUrl(listing, listing.commit);
  const data: Record<string, unknown> = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: listing.name,
    description: listing.description || listingSummary(listing),
    url,
    applicationCategory: "DeveloperApplication",
    applicationSubCategory: TIER_LABEL[listing.tier],
    operatingSystem: "macOS",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    image: listing.iconUrl ?? listingOpenGraphImage(listing),
    installUrl: `${url}/install`,
    codeRepository: source,
    sameAs: [repositoryUrl(listing)],
    isPartOf: { "@type": "WebSite", name: "cmux", url: SITE },
    author: {
      "@type": "Person",
      name: listing.publisher ?? listing.owner,
      url: `${SITE}${authorPath(listing.owner)}`,
    },
  };
  if (listing.categories.length > 0) data.keywords = listing.categories.join(", ");
  if (listing.license) data.license = listing.license;
  if (listing.screenshots.length > 0) data.screenshot = listing.screenshots;
  const modified = listing.latest?.date ?? listing.updatedAt;
  if (modified) data.dateModified = modified;
  if (listing.latest) data.softwareVersion = listing.latest.version;
  if (listing.requiresCmux) data.softwareRequirements = `cmux ${listing.requiresCmux} or later`;
  if (listing.downloads !== undefined) {
    data.interactionStatistic = {
      "@type": "InteractionCounter",
      interactionType: "https://schema.org/InstallAction",
      userInteractionCount: listing.downloads,
    };
  }
  return data;
}

/** schema.org ItemList for an index or author page. */
export function listingsItemListJsonLd(name: string, url: string, listings: readonly Listing[]): Record<string, unknown> {
  return {
    "@context": "https://schema.org",
    "@type": "ItemList",
    name,
    url,
    itemListElement: listings.map((listing, index) => ({
      "@type": "ListItem",
      position: index + 1,
      url: listingUrl(listing, listing.kind),
      name: listing.name,
    })),
  };
}
