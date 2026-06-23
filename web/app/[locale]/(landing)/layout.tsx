import { SiteFooter } from "../components/site-footer";
import { SiteHeader } from "../components/site-header";

// SEO landing pages (category + agent + Ghostty). Discovery surfaces for
// search: intentionally out of the main nav and docs sidebar, English-only in
// the sitemap and middleware (see web/app/sitemap.ts and web/proxy.ts), same
// convention as the (legal) group.
export default function LandingLayout({
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
