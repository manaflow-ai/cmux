import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { CodeBlock } from "../../components/code-block";

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
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("hierarchy")}</h2>
      <CodeBlock lang="text">{`Window
  └── Workspace (sidebar entry)
        └── Pane (split region)
              └── Surface (tab within pane)
                    └── Panel (terminal or browser content)`}</CodeBlock>

      <h3>{t("windowTitle")}</h3>
      <p>
        {t("windowDesc", { shortcut: "⌘⇧N" })}
      </p>

      <h3>{t("workspaceTitle")}</h3>
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
            jump: "⌘1–⌘9",
            close: "⌘⇧W",
            prevNext: "⌃⌘[ / ⌃⌘]",
          })}
        </strong>
      </p>

      <h3>{t("paneTitle")}</h3>
      <p>
        {t("paneDesc", {
          right: "⌘D",
          down: "⌘⇧D",
          nav: "⌥⌘",
        })}
      </p>
      <p>{t("paneNote")}</p>

      <h3>{t("surfaceTitle")}</h3>
      <p>
        {t("surfaceDesc", {
          new: "⌘T",
          prev: "⌘[",
          next: "⌘]",
          jump: "⌃1–⌃9",
        })}
      </p>
      <p>{t("surfaceNote")}</p>

      <h3>{t("panelTitle")}</h3>
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

      <h2>{t("visualExample")}</h2>
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

      <h2>{t("summary")}</h2>
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
