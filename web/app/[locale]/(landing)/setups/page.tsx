import { ListingIndexPage, listingIndexMetadata } from "../extensions/listing-index";

export async function generateMetadata() {
  return listingIndexMetadata("setup");
}

export default function SetupsPage() {
  return <ListingIndexPage kind="setup" />;
}
