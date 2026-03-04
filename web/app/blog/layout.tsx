import type { Metadata } from "next";
import { SiteHeader } from "../components/site-header";
import { BlogPager } from "../components/blog-pager";
import { BlogCTA } from "../components/blog-cta";

export const metadata: Metadata = {
  title: {
    template: "%s — cmux blog",
    default: "cmux blog",
  },
  openGraph: {
    siteName: "cmux",
    type: "article",
  },
  alternates: {
    canonical: "./",
  },
};

export default function BlogLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen">
      <SiteHeader section="blog" />
      <main className="w-full max-w-5xl mx-auto px-6 py-10">
        <div className="docs-content text-[15px]">{children}</div>
        <BlogCTA />
        <BlogPager />
      </main>
    </div>
  );
}
