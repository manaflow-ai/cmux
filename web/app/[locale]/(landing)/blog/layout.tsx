import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { BlogPager } from "@/app/[locale]/components/blog-pager";
import { BlogCTA } from "@/app/[locale]/components/blog-cta";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog" });
  return {
    title: {
      template: `%s — ${t("layoutTitle")}`,
      default: t("layoutTitle"),
    },
    openGraph: {
      ...openGraphDefaults(locale, "article"),
    },
    alternates: buildAlternates(locale, "/blog"),
  };
}

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
