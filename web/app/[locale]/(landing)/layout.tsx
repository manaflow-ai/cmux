import { SiteHeader } from "../components/site-header";

// SEO landing pages (category + agent + Ghostty), localized, intentionally out
// of the main nav and docs sidebar. The site footer is rendered globally by
// [locale]/layout.tsx, so this layout only adds the header and the content
// container (same as the (legal) group).
export default function LandingLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen">
      <SiteHeader />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">{children}</div>
      </main>
    </div>
  );
}
