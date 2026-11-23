import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { JsonLd } from "@/app/[locale]/components/json-ld";
import { type Listing, loadAuthorListings } from "@/app/extensions/_lib/registry";
import { GITHUB_HOST, SITE, authorPath, isValidOwner } from "@/app/extensions/_lib/refs";
import { listingsItemListJsonLd } from "@/app/extensions/_lib/seo";
import { ListingIndexBody } from "../../extensions/listing-index";

// A listing page answers with its real status (404 for an unapproved repo) and full HTML for crawlers,
// so it renders before responding instead of streaming into an instant shell.
export const instant = false;

type Params = Promise<{ locale: string; name: string }>;

async function authorListings(params: Params): Promise<{ owner: string; listings: Listing[] } | null> {
  const { name } = await params;
  let owner: string;
  try {
    owner = decodeURIComponent(name);
  } catch {
    return null;
  }
  if (!isValidOwner(owner)) return null;
  const listings = (await loadAuthorListings(owner)) ?? [];
  if (listings.length === 0) return null;
  return { owner: listings[0]!.owner, listings };
}

/** The author's display name: the publisher their listings name most, else the owner. */
function displayName(owner: string, listings: readonly Listing[]): string {
  const counts = new Map<string, number>();
  for (const listing of listings) if (listing.publisher) counts.set(listing.publisher, (counts.get(listing.publisher) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] ?? owner;
}

export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  const found = await authorListings(params);
  if (!found) return { robots: { index: false, follow: false } };
  const t = await getTranslations("extensions");
  const name = displayName(found.owner, found.listings);
  const title = t("authorTitle", { owner: name });
  const description = t("authorIntro", { owner: name });
  const url = `${SITE}${authorPath({ host: GITHUB_HOST, owner: found.owner })}`;
  return {
    title: { absolute: title },
    description,
    alternates: { canonical: url },
    openGraph: { siteName: "cmux", type: "profile", title, description, url },
  };
}

export default async function AuthorPage({ params }: { params: Params }) {
  const found = await authorListings(params);
  if (!found) notFound();
  const t = await getTranslations("extensions");
  const name = displayName(found.owner, found.listings);
  const url = `${SITE}${authorPath({ host: GITHUB_HOST, owner: found.owner })}`;
  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="mx-auto w-full max-w-6xl px-6 py-10">
        <JsonLd
          data={{
            "@context": "https://schema.org",
            "@type": "ProfilePage",
            url,
            mainEntity: { "@type": "Person", name, alternateName: found.owner, url },
            hasPart: listingsItemListJsonLd(t("authorTitle", { owner: name }), url, found.listings),
          }}
        />
        <div className="mb-8 flex items-center gap-4">
          {/* eslint-disable-next-line @next/next/no-img-element -- the owner's GitHub avatar */}
          <img
            src={`https://github.com/${encodeURIComponent(found.owner)}.png?size=128`}
            alt=""
            width={64}
            height={64}
            referrerPolicy="no-referrer"
            className="rounded-full border border-border bg-code-bg"
          />
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">{name}</h1>
            <p className="mt-1 text-[15px] text-muted">{t("authorIntro", { owner: name })}</p>
          </div>
        </div>
        <ListingIndexBody kind="extension" listings={found.listings} showHowTo={false} />
      </main>
    </div>
  );
}
