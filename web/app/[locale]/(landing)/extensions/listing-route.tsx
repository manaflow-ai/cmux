import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { Link } from "@/i18n/navigation";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { type Listing, loadAuthorListings, loadListing } from "@/app/extensions/_lib/registry";
import {
  GITHUB_HOST,
  type ListingKind,
  type ListingRoute,
  installDeeplink,
  listingPath,
  listingUrl,
  parseListingSlug,
  remixDeeplink,
} from "@/app/extensions/_lib/refs";
import { listingMetadata } from "@/app/extensions/_lib/seo";
import { CliInstall, ListingDetail, ListingIcon } from "./listing-ui";
import { InstallHandoff } from "./install-handoff";

export type ListingRouteParams = Promise<{ locale: string; slug: string[] }>;

async function resolve(kind: ListingKind, params: ListingRouteParams): Promise<{ route: ListingRoute; listing: Listing } | null> {
  const { slug } = await params;
  const route = parseListingSlug(slug);
  if (!route) return null;
  const listing = await loadListing(kind, route);
  return listing ? { route, listing } : null;
}

const NOT_FOUND_METADATA: Metadata = { robots: { index: false, follow: false } };

export async function listingRouteMetadata(kind: ListingKind, params: ListingRouteParams): Promise<Metadata> {
  const found = await resolve(kind, params);
  if (!found) return NOT_FOUND_METADATA;
  const { route, listing } = found;
  if (route.page === "listing") return listingMetadata(listing);
  const t = await getTranslations("extensions");
  return {
    title: { absolute: `${t("installTitle", { name: listing.name })} | cmux` },
    description: t("installIntro", { name: listing.name }),
    // Per-click handoff pages: the listing page is the one to index.
    alternates: { canonical: listingUrl(listing, kind) },
    robots: { index: false, follow: true },
  };
}

export async function ListingRoutePage({ kind, params }: { kind: ListingKind; params: ListingRouteParams }) {
  const found = await resolve(kind, params);
  if (!found) notFound();
  const { route, listing } = found;
  const t = await getTranslations("extensions");
  const section = kind === "setup" ? t("setupsSection") : t("section");
  if (route.page !== "listing") {
    return (
      <div className="min-h-screen">
        <SiteHeader section={section} />
        <HandoffBody listing={listing} page={route.page} />
      </div>
    );
  }
  // "More by" reads the GitHub author index; an owner on another host has none (refs.ts authorPath).
  const others = listing.host === GITHUB_HOST ? ((await loadAuthorListings(listing.owner)) ?? []) : [];
  const more = others.filter((other) => listingPath(other, other.kind) !== listingPath(listing, kind));
  return (
    <div className="min-h-screen">
      <SiteHeader section={section} />
      <main className="mx-auto w-full max-w-6xl px-6 py-10">
        <nav aria-label="Breadcrumb" className="mb-6 text-[13px] text-muted">
          <Link href={kind === "setup" ? "/setups" : "/extensions"} className="hover:underline">
            {section}
          </Link>
          <span className="mx-1.5">/</span>
          <span>{listing.name}</span>
        </nav>
        <ListingDetail listing={listing} more={more} />
      </main>
    </div>
  );
}

async function HandoffBody({ listing, page }: { listing: Listing; page: "install" | "remix" }) {
  const t = await getTranslations("extensions");
  const href = page === "remix" ? remixDeeplink(listing, listing.commit) : installDeeplink(listing, listing.commit, listing.kind);
  const title = page === "remix" ? t("remixTitle", { name: listing.name }) : t("installTitle", { name: listing.name });
  const intro = page === "remix" ? t("remixIntro", { name: listing.name }) : t("installIntro", { name: listing.name });
  return (
    <main className="mx-auto w-full max-w-2xl px-6 py-12">
      <div className="mb-8 flex items-center gap-4">
        <ListingIcon listing={listing} size={56} />
        <div className="min-w-0">
          <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
          <p className="mt-1 text-[15px] text-muted">{intro}</p>
        </div>
      </div>
      <InstallHandoff
        href={href}
        autoOpen
        labels={{
          open: t("installOpen"),
          download: t("installDownload"),
          noCmux: t("installNoCmux"),
          downloadBody: t("installDownloadBody", { name: listing.name }),
        }}
      />
      {page === "install" ? (
        <div className="mt-6">
          <CliInstall listing={listing} label={t("installCommand")} copy={t("copy")} copied={t("copied")} />
        </div>
      ) : null}
      <p className="mt-6 text-[14px] text-muted">
        <Link href={listingPath(listing, listing.kind)} className="underline decoration-link-underline underline-offset-2">
          {t("installBack", { name: listing.name })}
        </Link>
        {" · "}
        <span>{t("pinned")}</span>
      </p>
    </main>
  );
}

