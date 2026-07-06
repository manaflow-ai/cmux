import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
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
    <>
      <div className="mb-10">
        <p className="mb-3 text-xs font-medium uppercase tracking-[0.16em] text-muted">
          {t("sectionMarker")}
        </p>
        <h1>{t("title")}</h1>
        <p>{t("intro")}</p>
      </div>
      <ExtensionsGallery />
    </>
  );
}
