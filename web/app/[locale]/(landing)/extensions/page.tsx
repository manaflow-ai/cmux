import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { buildAlternates } from "../../../../i18n/seo";
import { ExtensionsGallery } from "./extensions-gallery";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "extensions" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/extensions"),
  };
}

export default function ExtensionsPage() {
  const t = useTranslations("extensions");

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("sectionMarker")} />
      <main className="w-full max-w-6xl mx-auto px-6 py-10">
        <h1 className="text-2xl font-semibold tracking-tight mb-2">
          {t("title")}
        </h1>
        <p className="max-w-3xl text-muted text-[15px] mb-6">
          {t("intro")}
        </p>
        <ExtensionsGallery />
      </main>
    </div>
  );
}
