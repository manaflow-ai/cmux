import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { Callout } from "../../components/callout";
import { CodeBlock } from "../../components/code-block";
import { KeyboardShortcuts } from "../../keyboard-shortcuts";

const shortcutChordExample = `{
  "shortcuts": {
    "bindings": {
      "newSurface": ["ctrl+b", "c"],
      "showNotifications": ["ctrl+b", "i"],
      "toggleSidebar": "cmd+b",
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
      <h1>{t("title")}</h1>
      <p>{t("description")}</p>

      <h2 id="shortcut-chords" className="scroll-mt-24">{t("chordsTitle")}</h2>
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
