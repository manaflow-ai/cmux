import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { managedPoliciesDocsLocales } from "@/i18n/locale-availability";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

function assertSupportedLocale(locale: string) {
  if (
    !managedPoliciesDocsLocales.includes(
      locale as (typeof managedPoliciesDocsLocales)[number],
    )
  ) {
    notFound();
  }
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  return auditedDocsMetadata({
    locale,
    pageKey: "managedPolicies",
    path: "/docs/managed-policies",
    availableLocales: managedPoliciesDocsLocales,
  });
}

const sampleProfile = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.example.cmux.managed-policies</string>
            <key>PayloadUUID</key>
            <string>6D4A3E9C-1B2F-4C8D-9E0A-5F6B7C8D9E0F</string>
            <key>PayloadDisplayName</key>
            <string>cmux managed policies</string>
            <key>PayloadContent</key>
            <dict>
                <key>com.cmuxterm.app</key>
                <dict>
                    <key>Forced</key>
                    <array>
                        <dict>
                            <key>mcx_preference_settings</key>
                            <dict>
                                <key>DisableEmbeddedBrowser</key>
                                <true/>
                                <key>DisableRemoteControl</key>
                                <true/>
                            </dict>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
    </array>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadIdentifier</key>
    <string>com.example.cmux.managed-policies.profile</string>
    <key>PayloadUUID</key>
    <string>2A1B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D</string>
    <key>PayloadDisplayName</key>
    <string>cmux Managed Policies</string>
    <key>PayloadScope</key>
    <string>System</string>
</dict>
</plist>`;

export default async function ManagedPoliciesPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.managedPolicies" });

  return (
    <>
      <DocsSchema namespace="docs.managedPolicies" path="/docs/managed-policies" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>
      <p>{t("lockSummary")}</p>

      <DocsHeading level={2} id="payload-domain">{t("domainTitle")}</DocsHeading>
      <p>{t("domainDesc")}</p>
      <CodeBlock lang="text">{`com.cmuxterm.app`}</CodeBlock>
      <p>{t("domainChannels")}</p>

      <DocsHeading level={2} id="keys">{t("keysTitle")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("keyHeader")}</th>
            <th>{t("typeHeader")}</th>
            <th>{t("defaultHeader")}</th>
            <th>{t("behaviorHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><code>DisableEmbeddedBrowser</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("browserKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableRemoteControl</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("remoteKeyDesc")}</td>
          </tr>
        </tbody>
      </table>
      <ul>
        <li>{t("noteBoolean")}</li>
        <li>{t("noteForcedOnly")}</li>
        <li>{t("noteTiming")}</li>
      </ul>

      <DocsHeading level={2} id="lockability">{t("lockTitle")}</DocsHeading>
      <p>{t("lockDesc")}</p>

      <DocsHeading level={2} id="supported-versions">{t("supportTitle")}</DocsHeading>
      <ul>
        <li>{t("supportMacos")}</li>
        <li>{t("supportVersions")}</li>
        <li>{t("supportIos")}</li>
      </ul>

      <DocsHeading level={2} id="sample-profile">{t("sampleTitle")}</DocsHeading>
      <p>{t("sampleDesc")}</p>
      <CodeBlock lang="xml">{sampleProfile}</CodeBlock>

      <DocsHeading level={2} id="verify">{t("verifyTitle")}</DocsHeading>
      <p>{t("verifyDesc")}</p>
      <CodeBlock lang="bash">{`defaults read com.cmuxterm.app DisableEmbeddedBrowser
defaults read com.cmuxterm.app DisableRemoteControl
cmux browser status --json   # {"enabled": false, "managed": true, ...}`}</CodeBlock>
      <Callout>{t("verifyUi")}</Callout>
    </>
  );
}
