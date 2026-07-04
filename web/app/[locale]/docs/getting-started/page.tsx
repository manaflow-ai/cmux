import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { DocsSchema } from "../docs-schema";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";
import { DownloadButton } from "../../components/download-button";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.gettingStarted" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/getting-started"),
  };
}

export default function GettingStartedPage() {
  const t = useTranslations("docs.gettingStarted");

  return (
    <>
      <DocsSchema namespace="docs.gettingStarted" path="/docs/getting-started" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="install">{t("install")}</DocsHeading>

      <DocsHeading level={3} id="dmg-recommended">{t("dmgRecommended")}</DocsHeading>
      <div className="my-4">
        <DownloadButton />
      </div>
      <p>{t("dmgDesc")}</p>

      <DocsHeading level={3} id="homebrew">{t("homebrew")}</DocsHeading>
      <CodeBlock lang="bash">{`brew install --cask cmux`}</CodeBlock>
      <p>{t("updateLater")}</p>
      <CodeBlock lang="bash">{`brew upgrade --cask cmux`}</CodeBlock>

      <Callout>
        {t.rich("firstLaunchCallout", {
          strong: (chunks) => <strong>{chunks}</strong>,
        })}
      </Callout>

      <DocsHeading level={2} id="verify-title">{t("verifyTitle")}</DocsHeading>
      <p>{t("verifyDesc")}</p>
      <ul>
        <li>{t("verifyItem1")}</li>
        <li>{t("verifyItem2")}</li>
        <li>{t("verifyItem3")}</li>
      </ul>

      <DocsHeading level={2} id="cli-setup">{t("cliSetup")}</DocsHeading>
      <p>{t("cliDesc")}</p>
      <CodeBlock lang="bash">{`sudo ln -sf "/Applications/cmux.app/Contents/Resources/bin/cmux" /usr/local/bin/cmux`}</CodeBlock>
      <p>{t("cliThen")}</p>
      <CodeBlock lang="bash">{`cmux list-workspaces
cmux notify --title "Build Complete" --body "Your build finished"`}</CodeBlock>

      <DocsHeading level={2} id="auto-updates">{t("autoUpdates")}</DocsHeading>
      <p>{t("autoUpdatesDesc")}</p>

      <DocsHeading level={2} id="session-restore">{t("sessionRestore")}</DocsHeading>
      <p>{t("sessionRestoreDesc")}</p>
      <Callout>{t("sessionCallout")}</Callout>
      <p>
        {t.rich("sessionRestoreLink", {
          link: (chunks) => <Link href="/docs/session-restore">{chunks}</Link>,
        })}
      </p>

      <DocsHeading level={2} id="requirements">{t("requirements")}</DocsHeading>
      <ul>
        <li>{t("reqItem1")}</li>
        <li>{t("reqItem2")}</li>
      </ul>
    </>
  );
}
