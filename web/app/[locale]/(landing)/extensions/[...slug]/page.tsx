import { ListingRoutePage, listingRouteMetadata, type ListingRouteParams } from "../listing-route";

// A listing page answers with its real status (404 for an unapproved repo) and full HTML for crawlers,
// so it renders before responding instead of streaming into an instant shell.
export const instant = false;

export async function generateMetadata({ params }: { params: ListingRouteParams }) {
  return listingRouteMetadata("extension", params);
}

export default function ExtensionPage({ params }: { params: ListingRouteParams }) {
  return <ListingRoutePage kind="extension" params={params} />;
}
