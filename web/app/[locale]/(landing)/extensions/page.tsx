import { ListingIndexPage, listingIndexMetadata } from "./listing-index";

export async function generateMetadata() {
  return listingIndexMetadata("extension");
}

export default function ExtensionsPage() {
  return <ListingIndexPage kind="extension" />;
}
