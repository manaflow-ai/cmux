import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { JsonLd } from "@/app/[locale]/components/json-ld";
import { type Listing, type ListingTier, LISTING_TIERS, loadAllListings } from "@/app/extensions/_lib/registry";
import { KIND_ROOT, type ListingKind, SITE, listingPath } from "@/app/extensions/_lib/refs";
import { listingSummary, listingsItemListJsonLd } from "@/app/extensions/_lib/seo";
import { type BrowserCard, type BrowserTier, ListingBrowser } from "./listing-browser";
import { CopySnippet } from "./copy-snippet";

/** The public registry repo (contract.md "Obsidian model" A): listing is a pull request to it. */
export const REGISTRY_REPO = "manaflow-ai/cmux-extensions";

export const REGISTRY_FILE: Record<ListingTier, string> = {
  plugin: "extensions.json",
  theme: "themes.json",
  snippet: "snippets.json",
  setup: "setups.json",
};

/** GitHub's editor for a registry file: it forks the repo for the person and opens the pull request form. */
export function registryEditUrl(tier: ListingTier): string {
  return `https://github.com/${REGISTRY_REPO}/edit/main/${REGISTRY_FILE[tier]}`;
}

/** Index pages are English content (publishers write in English); every locale canonicalizes to it. */
export async function listingIndexMetadata(kind: ListingKind): Promise<Metadata> {
  const t = await getTranslations("extensions");
  const title = kind === "setup" ? t("setupsMetaTitle") : t("metaTitle");
  const description = kind === "setup" ? t("setupsMetaDescription") : t("metaDescription");
  const url = `${SITE}${KIND_ROOT[kind]}`;
  return {
    title: { absolute: title },
    description,
    alternates: { canonical: url },
    openGraph: { siteName: "cmux", type: "website", title, description, url, images: [`${SITE}/opengraph-image`] },
    twitter: { card: "summary_large_image", title, description, images: [`${SITE}/opengraph-image`] },
  };
}

export async function HowToList({ tier }: { tier: ListingTier }) {
  const t = await getTranslations("extensions");
  const code = (chunks: React.ReactNode) => <code className="rounded bg-code-bg px-1 py-0.5 font-mono text-[13px]">{chunks}</code>;
  const entry = `{ "id": "you/${tier === "setup" ? "my-setup" : "my-extension"}", "name": "...", "author": "you", "description": "...", "repo": "you/REPO" }`;
  const files: readonly ListingTier[] = tier === "setup" ? ["setup"] : ["plugin", "theme", "snippet"];
  return (
    <section id="list" aria-labelledby="list-title" className="mt-14 scroll-mt-20 rounded-2xl border border-border p-6">
      <h2 id="list-title" className="text-lg font-semibold tracking-tight">{tier === "setup" ? t("listSetupTitle") : t("listTitle")}</h2>
      <ol className="mt-3 list-decimal space-y-1.5 pl-5 text-[14px] leading-6">
        <li>
          {t.rich(tier === "setup" ? "listSetupStep1" : "listStep1", { code })}{" "}
          {t.rich("scaffoldHint", { command: tier === "setup" ? "cmux setup export DIR" : "cmux ext new", code })}
        </li>
        <li>{t.rich("listStep2", { code })}</li>
        <li>{t.rich("listStep3", { file: REGISTRY_FILE[tier], repo: REGISTRY_REPO, code })}</li>
      </ol>
      <div className="mt-4 max-w-3xl">
        <CopySnippet text={entry} copyLabel={t("copy")} copiedLabel={t("copied")} />
      </div>
      <div className="mt-4 flex flex-wrap gap-2">
        {files.map((value, index) => (
          <a
            key={value}
            href={registryEditUrl(value)}
            rel="noopener"
            className={
              index === 0
                ? "inline-flex items-center rounded-full bg-foreground px-5 py-2 text-[14px] font-medium transition-opacity hover:opacity-85"
                : "inline-flex items-center rounded-full border border-border px-4 py-2 text-[14px] font-medium transition-colors hover:bg-code-bg"
            }
            style={index === 0 ? { color: "var(--background)", textDecoration: "none" } : undefined}
          >
            {t("listOpenPr", { file: REGISTRY_FILE[value] })}
          </a>
        ))}
      </div>
    </section>
  );
}

function compactNumber(value: number): string {
  return new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

/** A card's plain data, with its labels already formatted on the server. */
export function browserCard(
  listing: Listing,
  labels: { downloads: (count: number, display: string) => string; updated: (date: string) => string },
): BrowserCard {
  const publisher = listing.publisher ?? listing.owner;
  const summary = listingSummary(listing);
  const updatedAt = listing.latest?.date ?? listing.updatedAt;
  const card: BrowserCard = {
    key: `${listing.kind}:${listingPath(listing, listing.kind)}`,
    href: listingPath(listing, listing.kind),
    tier: listing.tier,
    name: listing.name,
    summary,
    publisher,
    downloads: listing.downloads ?? 0,
    search: [listing.name, summary, publisher, listing.owner, listing.repo, ...listing.categories].join(" ").toLowerCase(),
  };
  if (listing.iconUrl) card.iconUrl = listing.iconUrl;
  if (listing.downloads !== undefined) card.downloadsLabel = labels.downloads(listing.downloads, compactNumber(listing.downloads));
  if (updatedAt) {
    card.updatedAt = updatedAt;
    card.updatedLabel = labels.updated(updatedAt.slice(0, 10));
  }
  if (listing.latest) card.version = listing.latest.version;
  return card;
}

function tierCounts(listings: readonly Listing[]): { present: ListingTier[]; tiers: Array<{ tier: BrowserTier; count: number }> } {
  const present = LISTING_TIERS.filter((tier) => listings.some((listing) => listing.tier === tier));
  const tiers: Array<{ tier: BrowserTier; count: number }> = present.map((tier) => ({
    tier,
    count: listings.filter((listing) => listing.tier === tier).length,
  }));
  if (present.length > 1) tiers.unshift({ tier: "all", count: listings.length });
  return { present, tiers };
}

export async function ListingIndexBody({
  kind,
  listings,
  showHowTo = true,
}: {
  kind: ListingKind;
  listings: Listing[] | null;
  /** The how-to-list block; an author page leaves it out. */
  showHowTo?: boolean;
}) {
  const t = await getTranslations("extensions");
  const listTier: ListingTier = kind === "setup" ? "setup" : "plugin";
  if (!listings || listings.length === 0) {
    return (
      <>
        <div className="rounded-2xl border border-dashed border-border px-6 py-10 text-center">
          <p className="text-[15px] font-medium">{listings ? t("emptyTitle") : t("unavailableTitle")}</p>
          <p className="mt-1 text-[14px] text-muted">{listings ? t("emptyBody") : t("unavailableBody")}</p>
        </div>
        <HowToList tier={listTier} />
      </>
    );
  }
  const cards = listings.map((listing) =>
    browserCard(listing, {
      downloads: (count, display) => t("downloads", { count, display }),
      updated: (date) => t("updatedOn", { date }),
    }),
  );
  const { present, tiers } = tierCounts(listings);
  const name = kind === "setup" ? t("setupsTitle") : t("title");
  return (
    <>
      {showHowTo ? <JsonLd data={listingsItemListJsonLd(`cmux ${name.toLowerCase()}`, `${SITE}${KIND_ROOT[kind]}`, listings)} /> : null}
      <ListingBrowser
        cards={cards}
        tiers={tiers}
        initialTier={present.length === 1 ? present[0] : "all"}
        labels={{
          search: t("searchPlaceholder"),
          tiers: { all: t("tierAll"), plugin: t("tierPlugin"), theme: t("tierTheme"), snippet: t("tierSnippet"), setup: t("tierSetup") },
          sort: t("sortLabel"),
          sorts: { popular: t("sortPopular"), updated: t("sortUpdated"), name: t("sortName") },
          noMatches: t("noMatches"),
        }}
      />
      {showHowTo ? <HowToList tier={listTier} /> : null}
    </>
  );
}

/** The extensions index shows every tier (plugins, themes, snippets and setups); /setups shows setups only. */
export async function loadIndexListings(kind: ListingKind): Promise<Listing[] | null> {
  const [extensions, setups] = await Promise.all([
    kind === "extension" ? loadAllListings("extension") : Promise.resolve<Listing[]>([]),
    loadAllListings("setup"),
  ]);
  if (extensions === null && setups === null) return null;
  return [...(extensions ?? []), ...(setups ?? [])];
}

export async function ListingIndexPage({ kind }: { kind: ListingKind }) {
  const t = await getTranslations("extensions");
  const listings = await loadIndexListings(kind);
  return (
    <div className="min-h-screen">
      <SiteHeader section={kind === "setup" ? t("setupsSection") : t("section")} />
      <main className="mx-auto w-full max-w-6xl px-6 py-10">
        <h1 className="mb-2 text-3xl font-semibold tracking-tight">{kind === "setup" ? t("setupsTitle") : t("title")}</h1>
        <p className="mb-8 max-w-2xl text-[15px] leading-7 text-muted">{kind === "setup" ? t("setupsIntro") : t("intro")}</p>
        <ListingIndexBody kind={kind} listings={listings} />
      </main>
    </div>
  );
}
