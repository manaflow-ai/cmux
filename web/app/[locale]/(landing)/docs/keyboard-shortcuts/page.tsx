import { useTranslations } from "next-intl";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { KeyboardShortcuts } from "@/app/[locale]/keyboard-shortcuts";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

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
  return auditedDocsMetadata({
    locale,
    pageKey: "keyboardShortcuts",
    path: "/docs/keyboard-shortcuts",
  });
}

/** Documents the default bindings and the syntax for customizing shortcuts. */
export default function KeyboardShortcutsPage() {
  const t = useTranslations("docs.keyboardShortcuts");

  return (
    <>
      <DocsSchema namespace="docs.keyboardShortcuts" path="/docs/keyboard-shortcuts" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("description")}</p>
      <p>{t("paneResizeDescription")}</p>

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

      <DocsHeading level={2} id="base-keymaps" className="scroll-mt-24">{t("presetsTitle")}</DocsHeading>
      <p>{t("presetsIntro")}</p>
      <ul>
        <li><strong>{t("presetCmuxLabel")}</strong> — {t("presetCmux")}</li>
        <li><strong>{t("presetIterm2Label")}</strong> — {t("presetIterm2")}</li>
        <li><strong>{t("presetTerminalLabel")}</strong> — {t("presetTerminal")}</li>
        <li><strong>{t("presetTmuxLabel")}</strong> — {t("presetTmux")}</li>
      </ul>
      <p>{t("presetsApply")}</p>
      <Callout type="info">{t("presetsPreserve")}</Callout>

      <KeyboardShortcuts />
    </>
  );
}
