import type { Metadata } from "next";
import { EnglishShell } from "@/app/[locale]/(landing)/extensions/english-shell";
import { ListingRoutePage, listingRouteMetadata } from "@/app/[locale]/(landing)/extensions/listing-route";

// Listing URLs with a dot in them (a spelled-out host, a repo named foo.js) reach this page:
// the request proxy leaves dotted paths out of the locale tree. See english-shell.tsx.
export const instant = false;

type Params = Promise<{ slug: string[] }>;

const withLocale = (params: Params) => params.then(({ slug }) => ({ locale: "en", slug }));

export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  return listingRouteMetadata("extension", withLocale(params));
}

export default function Page({ params }: { params: Params }) {
  return (
    <EnglishShell>
      <ListingRoutePage kind="extension" params={withLocale(params)} />
    </EnglishShell>
  );
}
