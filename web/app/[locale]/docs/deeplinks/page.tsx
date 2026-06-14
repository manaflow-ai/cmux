import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { CodeBlock } from "../../components/code-block";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.deeplinks" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/deeplinks"),
  };
}

export default function DeepLinksPage() {
  const t = useTranslations("docs.deeplinks");

  return (
    <>
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <p>{t("deepLinksDesc")}</p>
      <CodeBlock lang="text">{`cmux://ssh?host=dev.example.com
cmux://ssh?host=dev.example.com&user=alice&port=2222&title=GPU%20box
cmux://ssh?host=workspace123.vm-ssh.freestyle.sh&user=workspace123%2Csession-token
cmux://ssh?host=dev.example.com&host-key-policy=accept-new&no-focus=true`}</CodeBlock>
      <p>{t("deepLinksWebFallbackDesc")}</p>
      <CodeBlock lang="text">{`https://cmux.com/deeplink/ssh?host=workspace123.vm-ssh.freestyle.sh&user=workspace123%2Csession-token&title=Freestyle`}</CodeBlock>
      <p>{t("deepLinksPromptRulesDesc")}</p>
      <CodeBlock lang="text">{`https://cmux.com/deeplink/prompt?text=Review%20this%20branch
https://cmux.com/deeplink/rules?name=freestyle&text=Prefer%20commas,%20colons:%20and%20small%20PRs`}</CodeBlock>
      <p>{t("deepLinksIconDesc")}</p>
      <CodeBlock lang="text">{`https://cmux.com/cmux-icon.svg
https://cmux.com/logo.png`}</CodeBlock>
      <p>{t("deepLinksButtonDesc")}</p>
      <CodeBlock lang="tsx">{`const params = new URLSearchParams({
  host: "workspace123.vm-ssh.freestyle.sh",
  user: "workspace123,session-token",
  title: "Freestyle",
});

const href = "https://cmux.com/deeplink/ssh?" + params.toString();`}</CodeBlock>
      <table>
        <thead>
          <tr>
            <th>{t("deepLinkParam")}</th>
            <th>{t("deepLinkMeaning")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>host</code></td><td>{t("deepLinkHost")}</td></tr>
          <tr><td><code>user</code></td><td>{t("deepLinkUser")}</td></tr>
          <tr><td><code>port</code></td><td>{t("deepLinkPort")}</td></tr>
          <tr><td><code>title</code> / <code>name</code></td><td>{t("deepLinkTitle")}</td></tr>
          <tr><td><code>connect-timeout</code></td><td>{t("deepLinkConnectTimeout")}</td></tr>
          <tr><td><code>server-alive-interval</code></td><td>{t("deepLinkServerAliveInterval")}</td></tr>
          <tr><td><code>server-alive-count-max</code></td><td>{t("deepLinkServerAliveCountMax")}</td></tr>
          <tr><td><code>host-key-policy</code></td><td>{t("deepLinkHostKeyPolicy")}</td></tr>
          <tr><td><code>no-focus</code></td><td>{t("deepLinkNoFocus")}</td></tr>
        </tbody>
      </table>
      <p>{t("deepLinksSchemeDesc")}</p>
      <p>{t("deepLinksSecurityDesc")}</p>
    </>
  );
}
