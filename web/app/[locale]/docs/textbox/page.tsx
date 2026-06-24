import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { DocsSchema } from "../docs-schema";
import { Callout } from "../../components/callout";
import { CodeBlock } from "../../components/code-block";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.textBox" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/textbox"),
  };
}

export default function TextBoxPage() {
  const t = useTranslations("docs.textBox");

  return (
    <>
      <DocsSchema namespace="docs.textBox" path="/docs/textbox" />
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <Callout>{t("betaCallout")}</Callout>

      <h2>{t("defaultsTitle")}</h2>
      <p>{t("defaultsDesc")}</p>
      <ul>
        <li>{t("showSetting")}</li>
        <li>{t("focusSetting")}</li>
        <li>{t("maxLinesSetting")}</li>
      </ul>

      <h2>{t("configTitle")}</h2>
      <p>{t("configDesc")}</p>
      <CodeBlock title="~/.config/cmux/cmux.json" lang="json">{`{
  "terminal": {
    "showTextBoxOnNewTerminals": true,
    "focusTextBoxOnNewTerminals": false,
    "textBoxMaxLines": 10
  }
}`}</CodeBlock>
      <p>{t("focusNote")}</p>
    </>
  );
}
