import { useTranslations } from "next-intl";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { Callout } from "@/app/[locale]/components/callout";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "ios",
    path: "/docs/ios",
  });
}

const linkClass =
  "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

export default function IosPage() {
  const t = useTranslations("docs.ios");
  const setup = useTranslations("docs.iosSetup");

  return (
    <>
      <DocsSchema namespace="docs.ios" path="/docs/ios" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>
      <p><a href="#setup" className={linkClass}>{setup("title")}</a></p>

      <Callout>{t("betaNote")}</Callout>

      <DocsHeading level={2} id="access">{t("accessTitle")}</DocsHeading>
      <p>
        {t.rich("accessDesc", {
          foundersLink: (chunks) => (
            <a
              href="https://github.com/manaflow-ai/cmux#founders-edition"
              className={linkClass}
            >
              {chunks}
            </a>
          ),
        })}
      </p>

      <DocsHeading level={2} id="setup">{setup("title")}</DocsHeading>
      <p>{setup("intro")}</p>
      <DocsHeading level={3} id="setup-before-you-start">{setup("checklistTitle")}</DocsHeading>
      <ul><li>{setup("checklist1")}</li><li>{setup("checklist2")}</li><li>{setup("checklist3")}</li></ul>
      <p><Link href="/" className={linkClass}>{setup("downloadMac")}</Link>{" · "}<Link href="/ios" className={linkClass}>{setup("downloadIOS")}</Link></p>
      <DocsHeading level={3} id="setup-enable-pairing">{setup("macTitle")}</DocsHeading>
      <ol><li>{setup("mac1")}</li><li>{setup("mac2")}</li><li>{setup("mac3")}</li></ol>
      <Callout>{setup("pairingNote")}</Callout>
      <DocsHeading level={3} id="setup-connect">{setup("phoneTitle")}</DocsHeading>
      <ol><li>{setup("phone1")}</li><li>{setup("phone2")}</li><li>{setup("phone3")}</li><li>{setup("phone4")}</li></ol>
      <Callout>{setup("permissionsNote")}</Callout>
      <DocsHeading level={3} id="setup-tailscale">{setup("tailscaleTitle")}</DocsHeading>
      <ol><li>{setup("tailscale1")}</li><li>{setup("tailscale2")}</li><li>{setup("tailscale3")}</li><li>{setup("tailscale4")}</li></ol>
      <DocsHeading level={3} id="setup-notifications">{setup("notificationsTitle")}</DocsHeading>
      <ol><li>{setup("notifications1")}</li><li>{setup("notifications2")}</li><li>{setup("notifications3")}</li></ol>
      <p><Link href="/docs/notifications" className={linkClass}>{setup("notificationsLink")}</Link></p>
      <DocsHeading level={3} id="setup-verify">{setup("verifyTitle")}</DocsHeading>
      <ol><li>{setup("verify1")}</li><li>{setup("verify2")}</li><li>{setup("verify3")}</li></ol>
      <DocsHeading level={3} id="setup-troubleshooting">{setup("troubleshootTitle")}</DocsHeading>
      <p>{setup("troubleshootIntro")}</p>
      <DocsHeading level={3} id="setup-missing-mac">{setup("troubleshootPairingTitle")}</DocsHeading><p>{setup("troubleshootPairing")}</p>
      <DocsHeading level={3} id="setup-update-mac">{setup("troubleshootVersionTitle")}</DocsHeading><p>{setup("troubleshootVersion")}</p>
      <DocsHeading level={3} id="setup-cannot-connect">{setup("troubleshootNetworkTitle")}</DocsHeading><p>{setup("troubleshootNetwork")}</p>
      <DocsHeading level={3} id="setup-empty-list">{setup("troubleshootEmptyTitle")}</DocsHeading><p>{setup("troubleshootEmpty")}</p>
      <DocsHeading level={3} id="setup-support">{setup("helpTitle")}</DocsHeading>
      <p>{setup("helpBody")}</p>
      <p><Link href="/support" className={linkClass}>{setup("helpLink")}</Link></p>

      <DocsHeading level={2} id="prerequisites">{t("prereqTitle")}</DocsHeading>
      <p>{t("prereqIntro")}</p>
      <ul>
        <li>{t("prereq1")}</li>
        <li>{t("prereq2")}</li>
        <li>{t("prereq3")}</li>
      </ul>

      <DocsHeading level={2} id="networking">{t("networkingTitle")}</DocsHeading>
      <p>{t("networkingDesc")}</p>

      <DocsHeading level={3} id="tailscale">{t("tailscaleTitle")}</DocsHeading>
      <p>
        {t.rich("tailscaleDesc", {
          link: (chunks) => (
            <a href="https://tailscale.com" className={linkClass}>
              {chunks}
            </a>
          ),
        })}
      </p>

      <DocsHeading level={3} id="wireguard">{t("wireguardTitle")}</DocsHeading>
      <p>
        {t.rich("wireguardDesc", {
          link: (chunks) => (
            <a href="https://www.wireguard.com" className={linkClass}>
              {chunks}
            </a>
          ),
        })}
      </p>

      <Callout>{t("networkingNote")}</Callout>

      <DocsHeading level={2} id="pair">{t("pairTitle")}</DocsHeading>
      <ol>
        <li>{t("pairStep1")}</li>
        <li>{t("pairStep2")}</li>
        <li>{t("pairStep3")}</li>
      </ol>
      <p>{t("pairNote")}</p>

      <DocsHeading level={2} id="notifications">{t("notificationsTitle")}</DocsHeading>
      <p>
        {t.rich("notificationsDesc", {
          link: (chunks) => (
            <Link href="/docs/notifications" className={linkClass}>
              {chunks}
            </Link>
          ),
        })}
      </p>

      <DocsHeading level={2} id="data">{t("dataTitle")}</DocsHeading>
      <p>{t("dataIntro")}</p>
      <ul>
        <li>{t("data1")}</li>
        <li>{t("data2")}</li>
        <li>{t("data3")}</li>
      </ul>
      <Callout>{t("dataNot")}</Callout>

      <DocsHeading level={2} id="enterprise">{t("enterpriseTitle")}</DocsHeading>
      <p>
        {t.rich("enterpriseDesc", {
          link: (chunks) => (
            <a
              href="mailto:founders@manaflow.com?subject=cmux%20enterprise"
              className={linkClass}
            >
              {chunks}
            </a>
          ),
        })}
      </p>
    </>
  );
}
