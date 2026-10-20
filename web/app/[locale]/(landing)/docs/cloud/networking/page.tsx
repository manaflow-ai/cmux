import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "cloudNetworking",
    path: "/docs/cloud/networking",
  });
}

export default async function CloudNetworkingPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.cloudNetworking" });

  return (
    <>
      <DocsSchema namespace="docs.cloudNetworking" path="/docs/cloud/networking" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="files">{t("pushTitle")}</DocsHeading>
      <p>{t("pushDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm push brave-otter ./app ~/app
cmux vm push brave-otter . ~/repo --no-default-excludes
cmux vm push brave-otter . ~/repo --exclude dist --watch
cmux vm pull brave-otter ~/repo/report.html ./report.html`}</CodeBlock>
      <p>{t("pushLimit")}</p>
      <p>{t("pullDesc")}</p>

      <DocsHeading level={2} id="secret-files">{t("secretTitle")}</DocsHeading>
      <p>{t("secretDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm push --secret brave-otter ~/.npmrc ~/.npmrc`}</CodeBlock>

      <DocsHeading level={2} id="environment-variables">{t("envTitle")}</DocsHeading>
      <p>{t("envDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm env set brave-otter --from-file .env
op read op://dev/stripe/key | cmux vm env set brave-otter -
cmux vm env ls brave-otter
cmux vm env rm brave-otter STRIPE_KEY`}</CodeBlock>
      <p>{t("envTip")}</p>

      <DocsHeading level={2} id="ports">{t("portsTitle")}</DocsHeading>
      <p>{t("portsDesc")}</p>
      <p>{t("portsList")}</p>
      <CodeBlock lang="bash">{`cmux vm ports brave-otter
cmux vm open brave-otter:port/3000`}</CodeBlock>

      <DocsHeading level={2} id="desktop">{t("desktopTitle")}</DocsHeading>
      <p>{t("desktopDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm desktop brave-otter`}</CodeBlock>

      <DocsHeading level={2} id="private-network">{t("networkTitle")}</DocsHeading>
      <p>{t("networkDesc")}</p>
      <p>{t("networkPeers")}</p>
      <p>{t("networkMacs")}</p>

      <DocsHeading level={2} id="vpn">{t("vpnTitle")}</DocsHeading>
      <p>{t("vpnDesc")}</p>
      <CodeBlock lang="bash">{`cmux vpn up
cmux vpn status
cmux vpn down`}</CodeBlock>

      <DocsHeading level={2} id="public-urls">{t("publishTitle")}</DocsHeading>
      <p>{t("publishDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud domains publish brave-otter 3000
cmux cloud domains publish brave-otter 3000 --access team
cmux cloud domains publish brave-otter 8080 --access public --yes
cmux cloud domains list
cmux cloud domains grant <hostname> teammate@example.com
cmux cloud domains rm <hostname>`}</CodeBlock>
      <p>{t("accessModes")}</p>
      <ul>
        <li>{t("accessPersonal")}</li>
        <li>{t("accessTeam")}</li>
        <li>{t("accessPublic")}</li>
      </ul>
      <p>{t("accessSignIn")}</p>
      <p>{t("accessWarning")}</p>

      <DocsHeading level={2} id="custom-domains">{t("customDomainTitle")}</DocsHeading>
      <p>{t("customDomainDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud domains verify preview.example.com
cmux cloud domains publish brave-otter 3000 --domain app.preview.example.com`}</CodeBlock>
    </>
  );
}
