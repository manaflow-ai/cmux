import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.mobile" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/mobile"),
  };
}

const tailscaleDownloadURL = "https://tailscale.com/download";
const foundersEditionURL = "https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q";

export default function MobilePage() {
  const t = useTranslations("docs.mobile");

  return (
    <>
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="prerequisites">{t("prereqTitle")}</DocsHeading>
      <p>{t("prereqIntro")}</p>

      <DocsHeading level={3} id="prereq-tailscale">{t("prereqTailscaleTitle")}</DocsHeading>
      <p>{t("prereqTailscaleDesc")}</p>
      <p>
        <a href={tailscaleDownloadURL} target="_blank" rel="noopener noreferrer">
          {t("prereqTailscaleLink")}
        </a>
      </p>

      <DocsHeading level={3} id="prereq-account">{t("prereqAccountTitle")}</DocsHeading>
      <p>{t("prereqAccountDesc")}</p>

      <DocsHeading level={3} id="prereq-apps">{t("prereqAppsTitle")}</DocsHeading>
      <p>{t("prereqAppsDesc")}</p>

      <DocsHeading level={2} id="ios-app">{t("iosAppTitle")}</DocsHeading>
      <p>{t("iosAppDesc")}</p>
      <p>
        <a href={foundersEditionURL} target="_blank" rel="noopener noreferrer">
          {t("iosAppLink")}
        </a>
      </p>
      <p>{t("iosAppAfter")}</p>

      <DocsHeading level={2} id="enable-host">{t("enableTitle")}</DocsHeading>
      <p>{t("enableDesc")}</p>
      <ol>
        <li>{t("enableStep1")}</li>
        <li>{t("enableStep2")}</li>
      </ol>
      <p>{t("enableConfigNote")}</p>
      <CodeBlock lang="json">{`{
  "mobile.iOSPairingHost.enabled": true,
  "mobile.iOSPairingHost.port": 58465
}`}</CodeBlock>
      <p>{t("enableConfigDesc")}</p>

      <DocsHeading level={2} id="pair">{t("pairTitle")}</DocsHeading>

      <DocsHeading level={3} id="pair-mac">{t("pairMacTitle")}</DocsHeading>
      <ol>
        <li>{t("pairMacStep1")}</li>
        <li>{t("pairMacStep2")}</li>
      </ol>

      <DocsHeading level={3} id="pair-phone">{t("pairPhoneTitle")}</DocsHeading>
      <ol>
        <li>{t("pairPhoneStep1")}</li>
        <li>{t("pairPhoneStep2")}</li>
        <li>{t("pairPhoneStep3")}</li>
      </ol>
      <Callout>{t("pairManualNote")}</Callout>

      <DocsHeading level={2} id="troubleshooting">{t("troubleshootingTitle")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("tsSymptom")}</th>
            <th>{t("tsCause")}</th>
            <th>{t("tsFix")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{t("tsNoTailscaleSymptom")}</td>
            <td>{t("tsNoTailscaleCause")}</td>
            <td>{t("tsNoTailscaleFix")}</td>
          </tr>
          <tr>
            <td>{t("tsAccountSymptom")}</td>
            <td>{t("tsAccountCause")}</td>
            <td>{t("tsAccountFix")}</td>
          </tr>
          <tr>
            <td>{t("tsListenerSymptom")}</td>
            <td>{t("tsListenerCause")}</td>
            <td>{t("tsListenerFix")}</td>
          </tr>
          <tr>
            <td>{t("tsLocalNetworkSymptom")}</td>
            <td>{t("tsLocalNetworkCause")}</td>
            <td>{t("tsLocalNetworkFix")}</td>
          </tr>
          <tr>
            <td>{t("tsSlowSymptom")}</td>
            <td>{t("tsSlowCause")}</td>
            <td>{t("tsSlowFix")}</td>
          </tr>
        </tbody>
      </table>

      <p>
        {t.rich("relatedSsh", {
          link: (chunks) => <Link href="/docs/ssh">{chunks}</Link>,
        })}
      </p>
    </>
  );
}
