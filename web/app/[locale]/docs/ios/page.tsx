import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "../../../../i18n/navigation";
import { buildAlternates } from "../../../../i18n/seo";
import { DocsSchema } from "../docs-schema";
import { Callout } from "../../components/callout";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.ios" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/ios"),
  };
}

const linkClass =
  "underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors";

export default function IosPage() {
  const t = useTranslations("docs.ios");

  return (
    <>
      <DocsSchema namespace="docs.ios" path="/docs/ios" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

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
