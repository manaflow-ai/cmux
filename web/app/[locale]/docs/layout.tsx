import type { Metadata } from "next";
import { DocsNav } from "./docs-nav";
import { SiteHeader } from "../components/site-header";

export const metadata: Metadata = {
  title: {
    template: "%s — cmux docs",
    default: "cmux docs",
  },
  openGraph: {
    siteName: "cmux",
    type: "article",
  },
  alternates: {
    canonical: "./",
  },
};

export default function DocsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen">
      <SiteHeader section="docs" />
      <DocsNav>{children}</DocsNav>
    </div>
  );
}
