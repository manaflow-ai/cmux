import { SiteFooter } from "@/app/[locale]/components/site-footer";

// SEO landing pages (category + agent + Ghostty), localized, intentionally out
// of the main nav and docs sidebar. Pages own their header/content layout so
// moved marketing routes keep their existing chrome without duplication.
export default function LandingLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen">
      {children}
      <SiteFooter />
    </div>
  );
}
