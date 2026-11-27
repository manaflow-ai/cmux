// The App Store page with its Community tab on sample data, for the gallery
// (community.gallery.ts): the page's own stores over the mock provider plus the Community source.
import { useEffect, useState } from "react";
import { createStrings } from "../shared/i18n";
import { AppsPage } from "./AppsPage";
import { CommunityStore } from "./community";
import { CommunityMockProvider, sampleCommunity, type CommunityMockData } from "./communityMock";
import table from "./generated/strings.json";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";

export interface CommunityGalleryProps {
  /** The page's fragment: `#/community`, or `#/community?ref=...` for a listing's page. */
  hash: string;
  /** Which sample registry: the full sample, none (registry empty), or an owner that refuses. */
  data: "sample" | "empty" | "unreachable" | "refused" | "holding";
  /** Starts this row's install (the consent card's in-flight state). */
  install?: string;
}

function registry(data: CommunityGalleryProps["data"]): CommunityMockData {
  if (data === "empty") return { items: [] };
  if (data === "unreachable") return { items: [], error: "registry: route.not_found" };
  if (data === "refused") return { items: [], refuse: true };
  return { ...sampleCommunity(), holdInstall: data === "holding" };
}

export function CommunityGalleryDemo({ hash, data, install }: CommunityGalleryProps) {
  const [page] = useState(() => {
    const client = new CommunityMockProvider(new MockAppsProvider(), registry(data));
    const store = new AppsStore(client, hash);
    const community = new CommunityStore(client, (app) => store.install(app), hash);
    return { store, community, strings: createStrings(table) };
  });
  useEffect(() => {
    if (!install) return;
    const row = sampleCommunity().items.find((item) => item.ref === install);
    if (row) void page.community.install(row.install_app);
  }, [install, page]);
  return (
    <div style={{ display: "grid", width: "100%", height: "100%" }}>
      <AppsPage store={page.store} strings={page.strings} community={page.community} />
    </div>
  );
}
