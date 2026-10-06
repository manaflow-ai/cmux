import { SiteFooter } from "@/app/[locale]/components/site-footer";
import { HideOnDocs } from "@/app/[locale]/components/hide-on-docs";

// Pricing reads the billing interval from the URL before rendering its client
// state. Keep it outside the instant marketing group so URL data cannot leave
// an inert shell during a navigation or a dev HMR refresh.
export const instant = false;

export default function PricingLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen">
      {children}
      <HideOnDocs>
        <SiteFooter />
      </HideOnDocs>
    </div>
  );
}
