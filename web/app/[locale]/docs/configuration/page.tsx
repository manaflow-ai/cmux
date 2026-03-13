import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.configuration" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
  };
}

export default function ConfigurationPage() {
  const t = useTranslations("docs.configuration");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("configLocations")}</h2>
      <p>{t("configLocationsDesc")}</p>
      <ol>
        <li>
          <code>~/.config/ghostty/config</code>
        </li>
        <li>
          <code>~/Library/Application Support/com.mitchellh.ghostty/config</code>
        </li>
      </ol>
      <p>{t("createConfig")}</p>
      <CodeBlock lang="bash">{`mkdir -p ~/.config/ghostty
touch ~/.config/ghostty/config`}</CodeBlock>

      <h2>{t("appearance")}</h2>

      <h3>{t("font")}</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`font-family = JetBrains Mono
font-size = 14`}</CodeBlock>

      <h3>{t("colors")}</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Theme (or use individual colors below)
theme = Dracula

# Custom colors
background = #1e1e2e
foreground = #cdd6f4
cursor-color = #f5e0dc
cursor-text = #1e1e2e
selection-background = #585b70
selection-foreground = #cdd6f4`}</CodeBlock>

      <h3>{t("splitPanes")}</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Opacity for unfocused splits (0.0 to 1.0)
unfocused-split-opacity = 0.7

# Fill color for unfocused splits
unfocused-split-fill = #1e1e2e

# Divider color between splits
split-divider-color = #45475a`}</CodeBlock>

      <h2>{t("behavior")}</h2>

      <h3>{t("scrollback")}</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Number of lines to keep in scrollback buffer
scrollback-limit = 10000`}</CodeBlock>

      <h3>{t("workingDirectory")}</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Default directory for new terminals
working-directory = ~/Projects`}</CodeBlock>

      <h2>{t("appSettings")}</h2>
      <p>{t("appSettingsDesc", { shortcut: "⌘," })}</p>

      <h3>{t("themeMode")}</h3>
      <ul>
        <li>
          <strong>{t("themeSystem")}</strong>
        </li>
        <li>
          <strong>{t("themeLight")}</strong>
        </li>
        <li>
          <strong>{t("themeDark")}</strong>
        </li>
      </ul>

      <h3>{t("automationMode")}</h3>
      <p>{t("automationModeDesc")}</p>
      <ul>
        <li>
          <strong>{t("automationOff")}</strong>
        </li>
        <li>
          <strong>{t("automationCmux")}</strong>
        </li>
        <li>
          <strong>{t("automationAll")}</strong>
        </li>
      </ul>
      <Callout type="warn">{t("automationCallout")}</Callout>

      <h3>{t("browserLinkBehavior")}</h3>
      <p>{t("browserLinkDesc")}</p>
      <ul>
        <li>
          <strong>{t("browserHostsEmbed")}</strong>
        </li>
        <li>
          <strong>{t("browserHostsHttp")}</strong>
        </li>
      </ul>

      <h2>{t("exampleConfig")}</h2>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Font
font-family = SF Mono
font-size = 13

# Colors
theme = One Dark

# Scrollback
scrollback-limit = 50000

# Splits
unfocused-split-opacity = 0.85
split-divider-color = #3e4451

# Working directory
working-directory = ~/code`}</CodeBlock>
    </>
  );
}
