import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "cloudTroubleshooting",
    path: "/docs/cloud/troubleshooting",
  });
}

export default async function CloudTroubleshootingPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.cloudTroubleshooting" });

  return (
    <>
      <DocsSchema namespace="docs.cloudTroubleshooting" path="/docs/cloud/troubleshooting" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="security-model">{t("securityTitle")}</DocsHeading>
      <ul>
        <li>{t("secNoPorts")}</li>
        <li>{t("secSignOut")}</li>
        <li>{t("secNoTokens")}</li>
        <li>{t("secSecrets")}</li>
        <li>{t("secTransfers")}</li>
        <li>{t("secOneUser")}</li>
        <li>{t("secDiagnostics")}</li>
        <li>{t("secAdmins")}</li>
      </ul>

      <DocsHeading level={2} id="common-problems">{t("errorsTitle")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("symptomColumn")}</th>
            <th>{t("fixColumn")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>{t("errNotSeen")}</td><td>{t("fixNotSeen")}</td></tr>
          <tr><td>{t("errUnavailable")}</td><td>{t("fixUnavailable")}</td></tr>
          <tr><td>{t("errSignIn")}</td><td>{t("fixSignIn")}</td></tr>
          <tr><td>{t("errPlan")}</td><td>{t("fixPlan")}</td></tr>
          <tr><td>{t("errSize")}</td><td>{t("fixSize")}</td></tr>
          <tr><td>{t("errLimit")}</td><td>{t("fixLimit")}</td></tr>
          <tr><td>{t("errPool")}</td><td>{t("fixPool")}</td></tr>
          <tr><td>{t("errLocked")}</td><td>{t("fixLocked")}</td></tr>
          <tr><td>{t("errAgentMissing")}</td><td>{t("fixAgentMissing")}</td></tr>
          <tr><td>{t("errExecTimeout")}</td><td>{t("fixExecTimeout")}</td></tr>
          <tr><td>{t("errSlowFirst")}</td><td>{t("fixSlowFirst")}</td></tr>
          <tr><td>{t("errSnapshot")}</td><td>{t("fixSnapshot")}</td></tr>
          <tr><td>{t("errSsh")}</td><td>{t("fixSsh")}</td></tr>
          <tr><td>{t("errPushLarge")}</td><td>{t("fixPushLarge")}</td></tr>
          <tr><td>{t("errGitMissing")}</td><td>{t("fixGitMissing")}</td></tr>
          <tr><td>{t("errDisconnected")}</td><td>{t("fixDisconnected")}</td></tr>
          <tr><td>{t("errDomain")}</td><td>{t("fixDomain")}</td></tr>
          <tr><td>{t("errViewer")}</td><td>{t("fixViewer")}</td></tr>
          <tr><td>{t("errTransferDisabled")}</td><td>{t("fixTransferDisabled")}</td></tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="get-help">{t("supportTitle")}</DocsHeading>
      <p>{t("supportDesc")}</p>
    </>
  );
}
