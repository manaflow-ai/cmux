import { SiteFooter } from "../components/site-footer";
import { SiteHeader } from "../components/site-header";

// Comparison and category pages are discovery surfaces for search. They are
// intentionally left out of the main nav and docs sidebar, and the sitemap
// only declares their English URLs (see web/app/sitemap.ts). Content is
// English-only, matching the (legal) group convention.
export default function CompareLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen flex flex-col">
      <SiteHeader />
      <main className="w-full max-w-3xl mx-auto px-6 py-12 flex-1">
        <div className="docs-content text-[15px]">{children}</div>
      </main>
      <SiteFooter />
    </div>
  );
}
