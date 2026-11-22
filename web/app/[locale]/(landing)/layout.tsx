import { SiteFooter } from "@/app/[locale]/components/site-footer";
import { HideOnDocs } from "@/app/[locale]/components/hide-on-docs";

export const instant = true;

// Every public marketing page (home, pricing, enterprise, support, docs, blog,
// downloads, SEO landing pages) lives in this group so it gets the site
// footer. Pages own their header/content layout; docs renders the footer
// inside its content column instead. Legal pages use their own layout.
export default function LandingLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen">
      {children}
      <HideOnDocs>
        <SiteFooter />
      </HideOnDocs>
    </div>
  );
}
