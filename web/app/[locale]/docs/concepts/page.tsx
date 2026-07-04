import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { DocsSchema } from "../docs-schema";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.concepts" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/concepts"),
  };
}

export default function ConceptsPage() {
  const t = useTranslations("docs.concepts");

  return (
    <>
      <DocsSchema namespace="docs.concepts" path="/docs/concepts" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="hierarchy">{t("hierarchy")}</DocsHeading>
      <CodeBlock lang="text">{`Window
  └── Workspace (sidebar entry)
        └── Pane (split region)
              └── Surface (tab within pane)
                    └── Panel (terminal or browser content)`}</CodeBlock>

      <DocsHeading level={3} id="window-title">{t("windowTitle")}</DocsHeading>
      <p>
        {t("windowDesc", { shortcut: "⌘⇧N" })}
      </p>

      <DocsHeading level={3} id="workspace-title">{t("workspaceTitle")}</DocsHeading>
      <p>{t("workspaceDesc")}</p>
      <p>{t("workspaceNote")}</p>

      <table>
        <thead>
          <tr>
            <th>{t("contextHeader")}</th>
            <th>{t("termUsedHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{t("sidebarUI")}</td>
            <td>{t("tab")}</td>
          </tr>
          <tr>
            <td>{t("keyboardShortcuts")}</td>
            <td>{t("workspaceOrTab")}</td>
          </tr>
          <tr>
            <td>{t("socketAPI")}</td>
            <td>
              <code>workspace</code>
            </td>
          </tr>
          <tr>
            <td>{t("environmentVariable")}</td>
            <td>
              <code>CMUX_WORKSPACE_ID</code>
            </td>
          </tr>
        </tbody>
      </table>

      <p>
        <strong>
          {t("workspaceShortcuts", {
            new: "⌘N",
            jump: "⌃1–⌃9",
            close: "⌘⇧W",
            prevNext: "⌃⌘[ / ⌃⌘]",
          })}
        </strong>
      </p>

      <DocsHeading level={3} id="pane-title">{t("paneTitle")}</DocsHeading>
      <p>
        {t("paneDesc", {
          right: "⌘D",
          down: "⌘⇧D",
          nav: "⌥⌘",
        })}
      </p>
      <p>{t("paneNote")}</p>

      <DocsHeading level={3} id="surface-title">{t("surfaceTitle")}</DocsHeading>
      <p>
        {t("surfaceDesc", {
          new: "⌘T",
          prev: "⌘[",
          next: "⌘]",
          jump: "⌘1–⌘9",
        })}
      </p>
      <p>{t("surfaceNote")}</p>

      <DocsHeading level={3} id="panel-title">{t("panelTitle")}</DocsHeading>
      <p>{t("panelDesc")}</p>
      <ul>
        <li>
          <strong>{t("panelTerminal")}</strong>
        </li>
        <li>
          <strong>{t("panelBrowser")}</strong>
        </li>
      </ul>
      <p>{t("panelNote")}</p>

      <DocsHeading level={2} id="workspace-groups">{t("workspaceGroups")}</DocsHeading>
      <p>{t("workspaceGroupsDesc")}</p>
      <p>
        <Link href="/docs/workspace-groups">{t("workspaceGroupsLink")}</Link>
      </p>

      <DocsHeading level={2} id="visual-example">{t("visualExample")}</DocsHeading>
      <CodeBlock variant="ascii">{`┌──────────────────────────────────────────────────────┐
│ ┌──────────┐ ┌─────────────────────────────────────┐ │
│ │ Sidebar  │ │ Workspace "dev"                     │ │
│ │          │ │                                     │ │
│ │          │ │ ┌───────────────┬─────────────────┐ │ │
│ │ > dev    │ │ │ Pane 1        │ Pane 2          │ │ │
│ │   server │ │ │ [S1] [S2]     │ [S1]            │ │ │
│ │   logs   │ │ │               │                 │ │ │
│ │          │ │ │  Terminal     │  Terminal       │ │ │
│ │          │ │ │               │                 │ │ │
│ │          │ │ └───────────────┴─────────────────┘ │ │
│ └──────────┘ └─────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘`}</CodeBlock>
      <p>{t("visualExampleDesc")}</p>
      <ul>
        <li>{t("visualItem1")}</li>
        <li>{t("visualItem2")}</li>
        <li>{t("visualItem3")}</li>
        <li>{t("visualItem4")}</li>
        <li>{t("visualItem5")}</li>
      </ul>

      <DocsHeading level={2} id="summary">{t("summary")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("levelHeader")}</th>
            <th>{t("whatItIsHeader")}</th>
            <th>{t("createdByHeader")}</th>
            <th>{t("identifiedByHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{t("windowTitle")}</td>
            <td>{t("macosWindow")}</td>
            <td>
              <code>⌘⇧N</code>
            </td>
            <td>—</td>
          </tr>
          <tr>
            <td>{t("workspaceTitle")}</td>
            <td>{t("sidebarEntry")}</td>
            <td>
              <code>⌘N</code>
            </td>
            <td>
              <code>CMUX_WORKSPACE_ID</code>
            </td>
          </tr>
          <tr>
            <td>{t("paneTitle")}</td>
            <td>{t("splitRegion")}</td>
            <td>
              <code>⌘D</code> / <code>⌘⇧D</code>
            </td>
            <td>{t("paneIdSocket")}</td>
          </tr>
          <tr>
            <td>{t("surfaceTitle")}</td>
            <td>{t("tabWithinPane")}</td>
            <td>
              <code>⌘T</code>
            </td>
            <td>
              <code>CMUX_SURFACE_ID</code>
            </td>
          </tr>
          <tr>
            <td>{t("panelTitle")}</td>
            <td>{t("terminalOrBrowser")}</td>
            <td>{t("automatic")}</td>
            <td>{t("panelIdInternal")}</td>
          </tr>
        </tbody>
      </table>
    </>
  );
}
