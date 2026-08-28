import Image from "next/image";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { Callout } from "@/app/[locale]/components/callout";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";
import { TuiInstallTabs } from "@/app/[locale]/(landing)/tui/install-tabs";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "tui.docs" });
  const alternates = buildAlternates(locale, "/docs/tui");
  const title = t("metaTitle");
  const description = t("metaDescription");

  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function TuiDocsPage() {
  const t = await getTranslations("tui.docs");

  return (
    <>
      <DocsHeading level={1} id="title">
        {t("title")}
      </DocsHeading>
      <p>{t("intro")}</p>
      <figure className="not-prose my-6">
        <Image
          src="/tui/cmux-tui-overview.png"
          width={5120}
          height={2820}
          sizes={
            "(min-width: 1152px) 856px, (min-width: 768px) calc(100vw - 19rem), calc(100vw - 3rem)"
          }
          alt={t("screenshotAlt")}
          className="h-auto w-full rounded-lg border border-border"
        />
        <figcaption className="mt-2 text-center font-mono text-[11px] text-muted">
          {t("screenshotCaption")}
        </figcaption>
      </figure>

      <DocsHeading level={2} id="install">
        {t("installTitle")}
      </DocsHeading>
      <p>{t("installIntro")}</p>
      <TuiInstallTabs
        unixLabel={t("installTabs.unix")}
        windowsLabel={t("installTabs.windows")}
        tabListLabel={t("installTabs.label")}
        viewScriptLabel={t("installTabs.viewScript")}
        copyLabel={t("installTabs.copy")}
        copiedLabel={t("installTabs.copied")}
      />
      <p>{t("installNpx")}</p>
      <CodeBlock lang="bash">{`npx cmux`}</CodeBlock>
      <Callout>{t("platforms")}</Callout>

      <DocsHeading level={2} id="model">
        {t("modelTitle")}
      </DocsHeading>
      <p>{t("modelIntro")}</p>
      <CodeBlock variant="ascii">{`session
└── workspaces
    └── screens
        └── panes
            └── tabs (terminal or browser surfaces)`}</CodeBlock>
      <p>{t("modelBody")}</p>

      <DocsHeading level={2} id="keyboard">
        {t("keyboardTitle")}
      </DocsHeading>
      <p>{t("keyboardIntro")}</p>
      <div className="not-prose my-4 overflow-x-auto rounded-lg border border-border">
        <table className="w-full min-w-[34rem] text-left text-[13px]">
          <thead className="bg-code-bg text-muted">
            <tr>
              <th className="px-4 py-2 font-medium">{t("keyTable.keys")}</th>
              <th className="px-4 py-2 font-medium">{t("keyTable.action")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {[
              ["Ctrl-b %", t("keys.splitRight")],
              ['Ctrl-b "', t("keys.splitDown")],
              ["Ctrl-b t", t("keys.newTab")],
              ["Ctrl-b W", t("keys.newWorkspace")],
              ["Ctrl-b s", t("keys.sidebar")],
              ["Ctrl-b d", t("keys.detach")],
            ].map(([keys, action]) => (
              <tr key={keys}>
                <td className="px-4 py-2.5 font-mono">{keys}</td>
                <td className="px-4 py-2.5 text-muted">{action}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p>{t("mouse")}</p>

      <DocsHeading level={2} id="sessions">
        {t("sessionsTitle")}
      </DocsHeading>
      <p>{t("sessionsIntro")}</p>
      <CodeBlock lang="bash">{`cmux --headless --session agents
cmux attach --session agents`}</CodeBlock>
      <p>{t("sessionsBody")}</p>

      <DocsHeading level={2} id="remote">
        {t("remoteTitle")}
      </DocsHeading>
      <p>{t("remoteIntro")}</p>
      <CodeBlock lang="json">{`{
  "machine_sidebar": { "enabled": true },
  "machines": [
    {
      "id": "buildbox",
      "name": "Build box",
      "transport": "ssh",
      "host": "dev@buildbox",
      "session": "agents"
    }
  ]
}`}</CodeBlock>
      <p>{t("remoteBody")}</p>

      <DocsHeading level={2} id="browser">
        {t("browserTitle")}
      </DocsHeading>
      <p>{t("browserBody")}</p>
      <CodeBlock lang="text">{`Ctrl-b B`}</CodeBlock>

      <DocsHeading level={2} id="automation">
        {t("automationTitle")}
      </DocsHeading>
      <p>{t("automationIntro")}</p>
      <CodeBlock lang="bash">{`cmux --session agents workspace list --json
workspace_id="$(cmux --session agents workspace create --name review --json | jq -r '.value.workspace_id')"
cmux --session agents workspace "$workspace_id" run -- npm test
cmux --session agents terminal <terminal-id> screen read`}</CodeBlock>
      <p>{t("automationBody")}</p>

      <DocsHeading level={2} id="configuration">
        {t("configTitle")}
      </DocsHeading>
      <p>{t("configBody")}</p>
      <CodeBlock lang="text">{`~/.config/cmux/cmux-tui.json`}</CodeBlock>

      <DocsHeading level={2} id="more">
        {t("moreTitle")}
      </DocsHeading>
      <ul>
        <li>
          <Link href="/tui">{t("links.product")}</Link>
        </li>
        <li>
          <a href="https://github.com/manaflow-ai/cmux/tree/main/cmux-tui/docs">
            {t("links.sourceDocs")}
          </a>
        </li>
        <li>
          <a href="https://github.com/manaflow-ai/cmux/tree/main/cmux-tui">
            {t("links.source")}
          </a>
        </li>
      </ul>
    </>
  );
}
