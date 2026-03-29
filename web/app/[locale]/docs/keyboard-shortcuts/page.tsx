import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { KeyboardShortcuts } from "../../keyboard-shortcuts";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.keyboardShortcuts" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/keyboard-shortcuts"),
  };
}

export default function KeyboardShortcutsPage() {
  const t = useTranslations("docs.keyboardShortcuts");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("description")}</p>
      <KeyboardShortcuts />
    </>
  );
}
