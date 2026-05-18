import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { Callout } from "../../components/callout";
import { CodeBlock } from "../../components/code-block";
import { KeyboardShortcuts } from "../../keyboard-shortcuts";
import { DocsHeading } from "../../components/docs-heading";

const shortcutChordExample = `{
  "shortcuts": {
    "bindings": {
      "newSurface": ["ctrl+b", "c"],
      "showNotifications": ["ctrl+b", "i"],
      "toggleSidebar": "cmd+b",
      "toggleFileExplorer": "cmd+opt+b",
      "splitRight": "",
      "commandPalettePrevious": null
    }
  }
}`;

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
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("description")}</p>

      <DocsHeading level={2} id="shortcut-chords" className="scroll-mt-24">{t("chordsTitle")}</DocsHeading>
      <p>
        {t.rich("chordsIntro", {
          settingsFile: (chunks) => <code>{chunks}</code>,
          configurationLink: (chunks) => <Link href="/docs/configuration">{chunks}</Link>,
        })}
      </p>
      <Callout type="info">{t("chordsCallout")}</Callout>
      <CodeBlock title="cmux.json" lang="json">{shortcutChordExample}</CodeBlock>
      <ul>
        <li>{t("chordsRuleSingle")}</li>
        <li>{t("chordsRuleArray")}</li>
        <li>{t("chordsRuleSyntax")}</li>
      </ul>

      <KeyboardShortcuts />
    </>
  );
}
