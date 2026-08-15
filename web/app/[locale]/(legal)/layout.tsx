import { SiteHeader } from "../components/site-header";
import { SiteFooter } from "@/app/[locale]/components/site-footer";

export default function LegalLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen">
      <SiteHeader />
      <main className="w-full max-w-6xl mx-auto px-6 py-10">
        <div className="docs-content text-[15px]">{children}</div>
      </main>
      <SiteFooter />
    </div>
  );
}
