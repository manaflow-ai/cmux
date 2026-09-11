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
                                <key>DisableCloud</key>
                                <true/>
                                <key>DisableRemoteConnections</key>
                                <true/>
                                <key>DisableFileTransfer</key>
                                <true/>
                                <key>DisableIrohNetworking</key>
                                <true/>
                                <key>DisableTelemetry</key>
                                <true/>
                                <key>DisableAutoUpdate</key>
                                <true/>
                                <key>DisableAutomationWebhooks</key>
                                <true/>
                                <key>DisableTLSTrustBypass</key>
                                <true/>
                                <key>DisableComputerUse</key>
                                <true/>
                                <key>DisableCustomSidebars</key>
                                <true/>
                                <key>DisableAICredentialUpload</key>
                                <true/>
                                <key>BrowserURLAllowlist</key>
                                <array>
                                    <string>https://git.example.com</string>
                                    <string>*.example.com</string>
                                </array>
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
          <tr>
            <td><code>DisableCloud</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("cloudKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableRemoteConnections</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("remoteConnectionsKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableFileTransfer</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("fileTransferKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableIrohNetworking</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("irohKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableTelemetry</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("telemetryKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableAutoUpdate</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("autoUpdateKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableAutomationWebhooks</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("webhooksKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableTLSTrustBypass</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("tlsBypassKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableComputerUse</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("computerUseKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableCustomSidebars</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("customSidebarsKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>DisableAICredentialUpload</code></td>
            <td>{t("booleanType")}</td>
            <td><code>false</code></td>
            <td>{t("aiCredentialUploadKeyDesc")}</td>
          </tr>
        </tbody>
      </table>
      <ul>
        <li>{t("noteBoolean")}</li>
        <li>{t("noteLaunchTimeKeys")}</li>
        <li>{t("noteForcedOnly")}</li>
        <li>{t("noteTiming")}</li>
        <li>{t("noteCloudEntitlement")}</li>
        <li>{t("noteComposition")}</li>
      </ul>

      <DocsHeading level={2} id="browser-allowlist">{t("allowlistTitle")}</DocsHeading>
      <p>{t("allowlistIntro")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("keyHeader")}</th>
            <th>{t("typeHeader")}</th>
            <th>{t("defaultHeader")}</th>
            <th>{t("allowlistBehaviorHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><code>BrowserURLAllowlist</code></td>
            <td>{t("stringArrayType")}</td>
            <td>{t("allowlistDefault")}</td>
            <td>{t("allowlistKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>BrowserAllowLocalhost</code></td>
            <td>{t("booleanType")}</td>
            <td><code>true</code></td>
            <td>{t("allowLocalhostKeyDesc")}</td>
          </tr>
          <tr>
            <td><code>BrowserAllowLocalFiles</code></td>
            <td>{t("booleanType")}</td>
            <td><code>true</code></td>
            <td>{t("allowLocalFilesKeyDesc")}</td>
          </tr>
        </tbody>
      </table>
      <p>{t("allowlistRules")}</p>
      <CodeBlock lang="text">{`git.example.com          # exactly this host, any port, http or https
*.example.com            # every subdomain of example.com (not example.com itself)
https://issues.example.com
http://localhost:3000    # only needed when BrowserAllowLocalhost is false`}</CodeBlock>
      <ul>
        <li>{t("allowlistNoteLocal")}</li>
        <li>{t("allowlistNoteEmpty")}</li>
        <li>{t("allowlistNoteScope")}</li>
        <li>{t("allowlistNoteBlockedPage")}</li>
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
defaults read com.cmuxterm.app DisableCloud
defaults read com.cmuxterm.app DisableRemoteConnections
defaults read com.cmuxterm.app DisableFileTransfer
defaults read com.cmuxterm.app DisableIrohNetworking
defaults read com.cmuxterm.app DisableTelemetry
defaults read com.cmuxterm.app DisableAutoUpdate
defaults read com.cmuxterm.app DisableAutomationWebhooks
defaults read com.cmuxterm.app DisableTLSTrustBypass
defaults read com.cmuxterm.app DisableComputerUse
defaults read com.cmuxterm.app DisableCustomSidebars
defaults read com.cmuxterm.app DisableAICredentialUpload
defaults read com.cmuxterm.app BrowserURLAllowlist
defaults read com.cmuxterm.app BrowserAllowLocalhost     # absent or 1 = allowed
defaults read com.cmuxterm.app BrowserAllowLocalFiles    # absent or 1 = allowed
cmux browser status --json   # url_allowlist, url_allowlist_managed, url_allowlist_allows_localhost, url_allowlist_allows_local_files
cmux vm list                 # refused: Cloud Machines are disabled by your administrator.`}</CodeBlock>
      <Callout>{t("verifyUi")}</Callout>
    </>
  );
}
