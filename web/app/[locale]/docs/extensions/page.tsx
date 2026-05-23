import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";
import { DocsHeading } from "../../components/docs-heading";

const contributionSurfaces = [
  {
    id: "terminal",
    field: "command",
    titleKey: "surfaceTerminalTitle",
    descriptionKey: "surfaceTerminalDescription",
  },
  {
    id: "actions",
    field: ".cmux/cmux.json actions",
    titleKey: "surfaceActionsTitle",
    descriptionKey: "surfaceActionsDescription",
  },
  {
    id: "dock",
    field: ".cmux/dock.json",
    titleKey: "surfaceDockTitle",
    descriptionKey: "surfaceDockDescription",
  },
  {
    id: "sidebar",
    field: "cmux report_meta",
    titleKey: "surfaceSidebarTitle",
    descriptionKey: "surfaceSidebarDescription",
  },
  {
    id: "markdown",
    field: "contributes.viewers.markdown",
    titleKey: "surfaceMarkdownTitle",
    descriptionKey: "surfaceMarkdownDescription",
  },
  {
    id: "diff",
    field: "contributes.viewers.diff",
    titleKey: "surfaceDiffTitle",
    descriptionKey: "surfaceDiffDescription",
  },
] as const;

const compatibilityChecks = [
  "compatManifest",
  "compatCommand",
  "compatEnv",
  "compatNoTmux",
  "compatRelativeAssets",
  "compatFallback",
] as const;

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.extensions" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/extensions"),
  };
}

export default function ExtensionsPage() {
  const t = useTranslations("docs.extensions");

  return (
    <>
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="install">{t("installTitle")}</DocsHeading>
      <p>{t("installIntro")}</p>
      <CodeBlock lang="bash">{`cmux use owner/repo
cmux use https://github.com/owner/repo
cmux use owner/repo --no-run
cmux use owner/repo --command "npm run dev"`}</CodeBlock>
      <Callout type="info">{t("installCallout")}</Callout>

      <DocsHeading level={2} id="layout">{t("layoutTitle")}</DocsHeading>
      <p>{t("layoutIntro")}</p>
      <CodeBlock lang="text">{`cmux.extension.json
README.md
viewer/
  markdown.css
  markdown.js
.cmux/
  cmux.json
  dock.json`}</CodeBlock>

      <DocsHeading level={2} id="manifest">{t("manifestTitle")}</DocsHeading>
      <p>{t("manifestIntro")}</p>
      <CodeBlock title="cmux.extension.json" lang="json">{`{
  "id": "acme.review-tools",
  "name": "Review Tools",
  "publisher": "acme",
  "version": "1.2.0",
  "engines": { "cmux": ">=0.65.0" },
  "permissions": ["terminal"],
  "install": {
    "command": "npm install"
  },
  "command": "npm run tui",
  "contributes": {
    "viewers": {
      "markdown": {
        "styles": ["viewer/markdown.css"],
        "scripts": ["viewer/markdown.js"]
      },
      "diff": {
        "styles": ["viewer/diff.css"],
        "scripts": ["viewer/diff.js"]
      }
    }
  }
}`}</CodeBlock>

      <DocsHeading level={2} id="surfaces">{t("surfacesTitle")}</DocsHeading>
      <p>{t("surfacesIntro")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("surfaceHeader")}</th>
            <th>{t("fieldHeader")}</th>
            <th>{t("behaviorHeader")}</th>
          </tr>
        </thead>
        <tbody>
          {contributionSurfaces.map((surface) => (
            <tr key={surface.id}>
              <td>{t(surface.titleKey)}</td>
              <td><code>{surface.field}</code></td>
              <td>{t(surface.descriptionKey)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <DocsHeading level={2} id="markdown-viewer">{t("markdownTitle")}</DocsHeading>
      <p>{t("markdownIntro")}</p>
      <CodeBlock title="viewer/markdown.js" lang="js">{`cmuxMarkdownViewer.register({
  afterRender({ content, markdown, isDark }) {
    content.querySelectorAll("table").forEach((table) => {
      table.dataset.extensionEnhanced = "review-tools";
    });
  },
  themeChanged({ content, isDark }) {
    content.dataset.theme = isDark ? "dark" : "light";
  }
});`}</CodeBlock>
      <Callout type="warn">{t("markdownSafety")}</Callout>

      <DocsHeading level={2} id="diff-viewer">{t("diffTitle")}</DocsHeading>
      <p>{t("diffIntro")}</p>
      <Callout type="info">{t("diffCallout")}</Callout>

      <DocsHeading level={2} id="app-ui">{t("appUITitle")}</DocsHeading>
      <p>{t("appUIIntro")}</p>
      <CodeBlock title=".cmux/cmux.json" lang="json">{`{
  "actions": {
    "review-tools.open": {
      "type": "command",
      "title": "Review Tools",
      "command": "cmux use acme/review-tools",
      "target": "newTabInCurrentPane",
      "palette": true,
      "icon": { "type": "symbol", "name": "checklist" }
    }
  },
  "ui": {
    "surfaceTabBar": {
      "buttons": [
        "cmux.newTerminal",
        "cmux.newBrowser",
        "cmux.splitRight",
        "cmux.splitDown",
        "review-tools.open"
      ]
    }
  }
}`}</CodeBlock>
      <CodeBlock title=".cmux/dock.json" lang="json">{`{
  "controls": [
    {
      "id": "review-tools-feed",
      "title": "Review Tools",
      "command": "cmux use acme/review-tools --command 'npm run feed'",
      "height": 320
    }
  ]
}`}</CodeBlock>
      <CodeBlock lang="bash">{`cmux report_meta review-tools "Ready" --icon=checkmark.circle --color=#34c759
cmux report_meta_block review-tools -- "### Review Tools\\nWaiting for a PR."
cmux set_progress 0.4`}</CodeBlock>

      <DocsHeading level={2} id="compatibility">{t("compatibilityTitle")}</DocsHeading>
      <p>{t("compatibilityIntro")}</p>
      <ul>
        {compatibilityChecks.map((key) => (
          <li key={key}>{t(key)}</li>
        ))}
      </ul>
    </>
  );
}
