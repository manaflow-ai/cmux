import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { Link } from "@/i18n/navigation";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "sessionRestore",
    path: "/docs/session-restore",
  });
}

export default async function SessionRestorePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.sessionRestore" });

  return (
    <>
      <DocsSchema namespace="docs.sessionRestore" path="/docs/session-restore" />
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("restoredTitle")}</h2>
      <p>{t("restoredDesc")}</p>
      <ul>
        <li>{t("restoredItemLayout")}</li>
        <li>{t("restoredItemCwd")}</li>
        <li>{t("restoredItemScrollback")}</li>
        <li>{t("restoredItemBrowser")}</li>
      </ul>

      <Callout>{t("liveProcessCallout")}</Callout>

      <h2>{t("agentResumeTitle")}</h2>
      <p>{t("agentResumeDesc")}</p>
      <CodeBlock lang="bash">{`cmux hooks setup
cmux hooks setup codex
cmux hooks setup grok
cmux hooks setup antigravity
cmux hooks setup omp
cmux hooks setup --agent opencode`}</CodeBlock>
      <p>{t("setupBehavior")}</p>

      <h2>{t("surfaceBindingsTitle")}</h2>
      <p>{t("surfaceBindingsDesc")}</p>
      <CodeBlock lang="bash">{`cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work`}</CodeBlock>
      <p>{t("surfaceBindingsNote")}</p>

      <h2>{t("supportedTitle")}</h2>
      <table>
        <thead>
          <tr>
            <th>{t("agentHeader")}</th>
            <th>{t("binaryHeader")}</th>
            <th>{t("resumeHeader")}</th>
            <th>{t("feedHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Claude Code</td>
            <td><code>claude</code></td>
            <td><code>claude --resume &lt;id&gt;</code></td>
            <td>{t("feedPermissionRequest")}</td>
          </tr>
          <tr>
            <td>Codex</td>
            <td><code>codex</code></td>
            <td><code>codex resume &lt;id&gt;</code></td>
            <td>{t("feedPreToolUsePermissionRequest")}</td>
          </tr>
          <tr>
            <td>Grok / Grok Build CLI</td>
            <td><code>grok</code></td>
            <td><code>grok -r &lt;id&gt;</code></td>
            <td>{t("feedPreToolUse")}</td>
          </tr>
          <tr>
            <td>OpenCode</td>
            <td><code>opencode</code></td>
            <td><code>opencode --session &lt;id&gt;</code></td>
            <td>{t("pluginEventBus")}</td>
          </tr>
          <tr>
            <td>Pi</td>
            <td><code>pi</code></td>
            <td><code>pi --session &lt;id&gt;</code></td>
            <td>{t("none")}</td>
          </tr>
          <tr>
            <td>OMP</td>
            <td><code>omp</code></td>
            <td><code>omp --session &lt;id&gt;</code></td>
            <td>{t("none")}</td>
          </tr>
          <tr>
            <td>Campfire</td>
            <td><code>campfire</code></td>
            <td><code>campfire --session &lt;id&gt;</code></td>
            <td>{t("none")}</td>
          </tr>
          <tr>
            <td>Amp</td>
            <td><code>amp</code></td>
            <td><code>amp threads continue &lt;id&gt;</code></td>
            <td>{t("none")}</td>
          </tr>
          <tr>
            <td>Cursor CLI</td>
            <td><code>cursor-agent</code></td>
            <td><code>cursor-agent --resume &lt;id&gt;</code></td>
            <td>{t("feedBeforeShellExecution")}</td>
          </tr>
          <tr>
            <td>Gemini</td>
            <td><code>gemini</code></td>
            <td><code>gemini --resume &lt;id&gt;</code></td>
            <td>{t("feedPreToolUse")}</td>
          </tr>
          <tr>
            <td>Antigravity CLI</td>
            <td><code>agy</code></td>
            <td><code>agy --conversation &lt;id&gt;</code></td>
            <td>{t("feedPrePostToolUse")}</td>
          </tr>
          <tr>
            <td>Rovo Dev</td>
            <td><code>acli</code></td>
            <td><code>acli rovodev run --restore &lt;id&gt;</code></td>
            <td>{t("none")}</td>
          </tr>
          <tr>
            <td>Hermes Agent</td>
            <td><code>hermes</code></td>
            <td><code>hermes --resume &lt;id&gt;</code></td>
            <td>{t("feedHermes")}</td>
          </tr>
          <tr>
            <td>Copilot</td>
            <td><code>copilot</code></td>
            <td><code>copilot --resume &lt;id&gt;</code></td>
            <td>{t("feedPreToolUse")}</td>
          </tr>
          <tr>
            <td>CodeBuddy</td>
            <td><code>codebuddy</code></td>
            <td><code>codebuddy --resume &lt;id&gt;</code></td>
            <td>{t("feedPreToolUse")}</td>
          </tr>
          <tr>
            <td>Factory</td>
            <td><code>droid</code></td>
            <td><code>droid --resume &lt;id&gt;</code></td>
            <td>{t("feedPreToolUse")}</td>
          </tr>
          <tr>
            <td>Qoder</td>
            <td><code>qodercli</code></td>
            <td><code>qodercli --resume &lt;id&gt;</code></td>
            <td>{t("feedPreToolUse")}</td>
          </tr>
        </tbody>
      </table>
      <p>{t("supportedNote")}</p>

      <h2>{t("manualTitle")}</h2>
      <p>{t("manualDesc")}</p>
      <ul>
        <li>{t("manualItemMenu")}</li>
        <li><code>⌘ ⇧ O</code></li>
        <li><code>cmux restore-session</code></li>
      </ul>

      <h2>{t("disableTitle")}</h2>
      <p>{t("disableDesc")}</p>
      <CodeBlock title="~/.config/cmux/cmux.json" lang="json">{`{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}`}</CodeBlock>
      <p>{t("disableNote")}</p>

      <h2>{t("underHoodTitle")}</h2>
      <ol>
        <li>{t("underHoodItemSnapshot")}</li>
        <li>{t("underHoodItemScrollback")}</li>
        <li>{t("underHoodItemHooks")}</li>
        <li>{t("underHoodItemResume")}</li>
      </ol>
      <p>
        {t.rich("underHoodMore", {
          configLink: (chunks) => <Link href="/docs/configuration">{chunks}</Link>,
        })}
      </p>
    </>
  );
}
