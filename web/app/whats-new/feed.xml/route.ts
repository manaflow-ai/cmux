import { compareWhatsNewVersions, type WhatsNewDocument } from "../../lib/whats-new";
import { nightlyDocuments } from "../../lib/whats-new-nightly";
import { whatsNewStore } from "../../lib/whats-new-store";
import { whatsNewAtomFeed } from "../../lib/whats-new-feed";

/** The What's New Atom feed: releases and nightly digests, newest first (K2). */
export async function GET(): Promise<Response> {
  const nightlies = await nightlyDocuments().catch(() => [] as WhatsNewDocument[]);
  const known = new Set(whatsNewStore.documents.map((document) => document.version));
  const documents = [...whatsNewStore.documents, ...nightlies.filter((document) => !known.has(document.version))]
    .sort((a, b) => compareWhatsNewVersions(b.version, a.version))
    .slice(0, 30);
  return new Response(whatsNewAtomFeed(documents, "https://cmux.com"), {
    headers: {
      "Cache-Control": "public, max-age=0, s-maxage=3600",
      "Content-Type": "application/atom+xml; charset=utf-8",
    },
  });
}
