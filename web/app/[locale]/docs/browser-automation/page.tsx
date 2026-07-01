import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { DocsSchema } from "../docs-schema";
import { CodeBlock } from "../../components/code-block";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.browserAutomation" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/browser-automation"),
  };
}

export default function BrowserAutomationPage() {
  const t = useTranslations("docs.browserAutomation");

  return (
    <>
      <DocsSchema namespace="docs.browserAutomation" path="/docs/browser-automation" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="command-index">{t("commandIndex")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("categoryHeader")}</th>
            <th>{t("subcommandsHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{t("navAndTargeting")}</td>
            <td>
              <code>identify</code>, <code>open</code>, <code>open-split</code>,{" "}
              <code>navigate</code>, <code>back</code>, <code>forward</code>,{" "}
              <code>reload</code>, <code>url</code>, <code>focus-webview</code>,{" "}
              <code>is-webview-focused</code>, <code>zoom</code>,{" "}
              <code>focus-mode</code>, <code>react-grab</code>, <code>devtools</code>
            </td>
          </tr>
          <tr>
            <td>{t("waiting")}</td>
            <td>
              <code>wait</code>
            </td>
          </tr>
          <tr>
            <td>{t("domInteraction")}</td>
            <td>
              <code>click</code>, <code>dblclick</code>, <code>hover</code>,{" "}
              <code>focus</code>, <code>check</code>, <code>uncheck</code>,{" "}
              <code>scroll-into-view</code>, <code>type</code>, <code>fill</code>,{" "}
              <code>press</code>, <code>keydown</code>, <code>keyup</code>,{" "}
              <code>select</code>, <code>scroll</code>
            </td>
          </tr>
          <tr>
            <td>{t("inspection")}</td>
            <td>
              <code>snapshot</code>, <code>screenshot</code>, <code>get</code>,{" "}
              <code>is</code>, <code>find</code>, <code>highlight</code>
            </td>
          </tr>
          <tr>
            <td>{t("jsAndInjection")}</td>
            <td>
              <code>eval</code>, <code>addinitscript</code>, <code>addscript</code>,{" "}
              <code>addstyle</code>
            </td>
          </tr>
          <tr>
            <td>{t("framesDialogsDownloads")}</td>
            <td>
              <code>frame</code>, <code>dialog</code>, <code>download</code>
            </td>
          </tr>
          <tr>
            <td>{t("stateAndSession")}</td>
            <td>
              <code>cookies</code>, <code>storage</code>, <code>state</code>,{" "}
              <code>history</code>
            </td>
          </tr>
          <tr>
            <td>{t("tabsAndLogs")}</td>
            <td>
              <code>tab</code>, <code>console</code>, <code>errors</code>
            </td>
          </tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="targeting-surface">{t("targetingSurface")}</DocsHeading>
      <p>{t("targetingDesc")}</p>
      <CodeBlock lang="bash">{`# Open a new browser split
cmux browser open https://example.com

# Discover focused IDs and browser metadata
cmux browser identify
cmux browser identify --surface surface:2

# Positional vs flag targeting are equivalent
cmux browser surface:2 url
cmux browser --surface surface:2 url`}</CodeBlock>

      <DocsHeading level={2} id="navigation">{t("navigation")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux browser open https://example.com
cmux browser open-split https://news.ycombinator.com

cmux browser surface:2 navigate https://example.org/docs --snapshot-after
cmux browser surface:2 back
cmux browser surface:2 forward
cmux browser surface:2 reload --snapshot-after
cmux browser surface:2 url

cmux browser surface:2 focus-webview
cmux browser surface:2 is-webview-focused

cmux browser react-grab toggle
cmux browser devtools toggle
cmux browser devtools console
cmux browser focus-mode toggle
cmux browser zoom in
cmux browser zoom reset
cmux browser history clear --force`}</CodeBlock>

      <DocsHeading level={2} id="waiting-section">{t("waitingSection")}</DocsHeading>
      <p>{t("waitingDesc")}</p>
      <CodeBlock lang="bash">{`cmux browser surface:2 wait --load-state complete --timeout-ms 15000
cmux browser surface:2 wait --selector "#checkout" --timeout-ms 10000
cmux browser surface:2 wait --text "Order confirmed"
cmux browser surface:2 wait --url-contains "/dashboard"
cmux browser surface:2 wait --function "window.__appReady === true"`}</CodeBlock>

      <DocsHeading level={2} id="dom-section">{t("domSection")}</DocsHeading>
      <p>{t("domDesc")}</p>
      <CodeBlock lang="bash">{`cmux browser surface:2 click "button[type='submit']" --snapshot-after
cmux browser surface:2 dblclick ".item-row"
cmux browser surface:2 hover "#menu"
cmux browser surface:2 focus "#email"
cmux browser surface:2 check "#terms"
cmux browser surface:2 uncheck "#newsletter"
cmux browser surface:2 scroll-into-view "#pricing"

cmux browser surface:2 type "#search" "cmux"
cmux browser surface:2 fill "#email" --text "ops@example.com"
cmux browser surface:2 fill "#email" --text ""
cmux browser surface:2 press Enter
cmux browser surface:2 keydown Shift
cmux browser surface:2 keyup Shift
cmux browser surface:2 select "#region" "us-east"
cmux browser surface:2 scroll --dy 800 --snapshot-after
cmux browser surface:2 scroll --selector "#log-view" --dx 0 --dy 400`}</CodeBlock>

      <DocsHeading level={2} id="inspection-section">{t("inspectionSection")}</DocsHeading>
      <p>{t("inspectionDesc")}</p>
      <CodeBlock lang="bash">{`cmux browser surface:2 snapshot --interactive --compact
cmux browser surface:2 snapshot --selector "main" --max-depth 5
cmux browser surface:2 screenshot --out /tmp/cmux-page.png

cmux browser surface:2 get title
cmux browser surface:2 get url
cmux browser surface:2 get text "h1"
cmux browser surface:2 get html "main"
cmux browser surface:2 get value "#email"
cmux browser surface:2 get attr "a.primary" --attr href
cmux browser surface:2 get count ".row"
cmux browser surface:2 get box "#checkout"
cmux browser surface:2 get styles "#total" --property color

cmux browser surface:2 is visible "#checkout"
cmux browser surface:2 is enabled "button[type='submit']"
cmux browser surface:2 is checked "#terms"

cmux browser surface:2 find role button --name "Continue"
cmux browser surface:2 find text "Order confirmed"
cmux browser surface:2 find label "Email"
cmux browser surface:2 find placeholder "Search"
cmux browser surface:2 find alt "Product image"
cmux browser surface:2 find title "Open settings"
cmux browser surface:2 find testid "save-btn"
cmux browser surface:2 find first ".row"
cmux browser surface:2 find last ".row"
cmux browser surface:2 find nth 2 ".row"

cmux browser surface:2 highlight "#checkout"`}</CodeBlock>

      <DocsHeading level={2} id="js-section">{t("jsSection")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux browser surface:2 eval "document.title"
cmux browser surface:2 eval --script "window.location.href"

cmux browser surface:2 addinitscript "window.__cmuxReady = true;"
cmux browser surface:2 addscript "document.querySelector('#name')?.focus()"
cmux browser surface:2 addstyle "#debug-banner { display: none !important; }"`}</CodeBlock>

      <DocsHeading level={2} id="state-section">{t("stateSection")}</DocsHeading>
      <p>{t("stateDesc")}</p>
      <CodeBlock lang="bash">{`cmux browser surface:2 cookies get
cmux browser surface:2 cookies get --name session_id
cmux browser surface:2 cookies set session_id abc123 --domain example.com --path /
cmux browser surface:2 cookies clear --name session_id
cmux browser surface:2 cookies clear --all

cmux browser surface:2 storage local set theme dark
cmux browser surface:2 storage local get theme
cmux browser surface:2 storage local clear
cmux browser surface:2 storage session set flow onboarding
cmux browser surface:2 storage session get flow

cmux browser surface:2 state save /tmp/cmux-browser-state.json
cmux browser surface:2 state load /tmp/cmux-browser-state.json`}</CodeBlock>

      <DocsHeading level={2} id="tabs-section">{t("tabsSection")}</DocsHeading>
      <p>{t("tabsDesc")}</p>
      <CodeBlock lang="bash">{`cmux browser surface:2 tab list
cmux browser surface:2 tab new https://example.com/pricing

# Switch by index or by target surface
cmux browser surface:2 tab switch 1
cmux browser surface:2 tab switch surface:7

# Close current tab or a specific target
cmux browser surface:2 tab close
cmux browser surface:2 tab close surface:7`}</CodeBlock>

      <DocsHeading level={2} id="console-section">{t("consoleSection")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux browser surface:2 console list
cmux browser surface:2 console clear

cmux browser surface:2 errors list
cmux browser surface:2 errors clear`}</CodeBlock>

      <DocsHeading level={2} id="dialogs-section">{t("dialogsSection")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux browser surface:2 dialog accept
cmux browser surface:2 dialog accept "Confirmed by automation"
cmux browser surface:2 dialog dismiss`}</CodeBlock>

      <DocsHeading level={2} id="frames-section">{t("framesSection")}</DocsHeading>
      <CodeBlock lang="bash">{`# Enter an iframe context
cmux browser surface:2 frame "iframe[name='checkout']"
cmux browser surface:2 click "#pay-now"

# Return to the top-level document
cmux browser surface:2 frame main`}</CodeBlock>

      <DocsHeading level={2} id="downloads-section">{t("downloadsSection")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux browser surface:2 click "a#download-report"
cmux browser surface:2 download --path /tmp/report.csv --timeout-ms 30000`}</CodeBlock>

      <DocsHeading level={2} id="common-patterns">{t("commonPatterns")}</DocsHeading>

      <DocsHeading level={3} id="pattern-navigate">{t("patternNavigate")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux browser open https://example.com/login
cmux browser surface:2 wait --load-state complete --timeout-ms 15000
cmux browser surface:2 snapshot --interactive --compact
cmux browser surface:2 get title`}</CodeBlock>

      <DocsHeading level={3} id="pattern-form">{t("patternForm")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux browser surface:2 fill "#email" --text "ops@example.com"
cmux browser surface:2 fill "#password" --text "$PASSWORD"
cmux browser surface:2 click "button[type='submit']" --snapshot-after
cmux browser surface:2 wait --text "Welcome"
cmux browser surface:2 is visible "#dashboard"`}</CodeBlock>

      <DocsHeading level={3} id="pattern-debug">{t("patternDebug")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux browser surface:2 console list
cmux browser surface:2 errors list
cmux browser surface:2 screenshot --out /tmp/cmux-failure.png
cmux browser surface:2 snapshot --interactive --compact`}</CodeBlock>

      <DocsHeading level={3} id="pattern-session">{t("patternSession")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux browser surface:2 state save /tmp/session.json
# ...later...
cmux browser surface:2 state load /tmp/session.json
cmux browser surface:2 reload`}</CodeBlock>
    </>
  );
}
