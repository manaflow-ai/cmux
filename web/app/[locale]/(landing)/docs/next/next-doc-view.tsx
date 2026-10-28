import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";
import cliReference from "@/data/next-docs/cli-reference.generated.json";
import settingsReference from "@/data/next-docs/settings-reference.generated.json";
import type { CliReference, SettingsReference } from "@/scripts/export-next-docs";
import { headingId, type DocBlock, type NextDocPage } from "@/data/next-docs/pages";

function Block({ block }: { block: DocBlock }) {
  if ("h2" in block) return <DocsHeading level={2} id={headingId(block.h2)}>{block.h2}</DocsHeading>;
  if ("p" in block) return <p>{block.p}</p>;
  if ("ul" in block) return <ul>{block.ul.map((item) => <li key={item}>{item}</li>)}</ul>;
  if ("code" in block) return <CodeBlock lang={block.lang ?? "bash"}>{block.code}</CodeBlock>;
  return <Callout type="info">{block.note}</Callout>;
}

function formatValue(value: unknown): string {
  if (value === null || value === undefined) return "";
  return typeof value === "string" ? value : JSON.stringify(value);
}

function CliTables() {
  const reference = cliReference as CliReference;
  return (
    <>
      <p>
        {reference.counts.verbs} commands, {reference.counts.mcp} of them also MCP tools.
      </p>
      {reference.nouns.map((entry) => (
        <section key={entry.noun}>
          <DocsHeading level={2} id={`cmux-${entry.noun}`}>{`cmux ${entry.noun}`}</DocsHeading>
          <table>
            <thead>
              <tr><th>Command</th><th>What it does</th><th>MCP</th></tr>
            </thead>
            <tbody>
              {entry.verbs.map((verb) => (
                <tr key={verb.id}>
                  <td><code>{verb.command}</code></td>
                  <td>{verb.title}</td>
                  <td>{verb.mcp ? "yes" : "no"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ))}
    </>
  );
}

function SettingsTables() {
  const reference = settingsReference as SettingsReference;
  return (
    <>
      <p>{reference.count} settings.</p>
      {reference.sections.map((section) => (
        <section key={section.id}>
          <DocsHeading level={2} id={section.id}>{section.title}</DocsHeading>
          <table>
            <thead>
              <tr><th>Key</th><th>Setting</th><th>Default</th></tr>
            </thead>
            <tbody>
              {section.rows.map((row) => (
                <tr key={row.key}>
                  <td><code>{row.key}</code></td>
                  <td>
                    {row.title}
                    {row.help ? <> — {row.help}</> : null}
                    {row.values ? <> Values: {row.values.map(formatValue).join(", ")}.</> : null}
                    {row.range ? <> Range: {formatValue(row.range.min)} to {formatValue(row.range.max)}{row.range.unit ? ` ${row.range.unit}` : ""}.</> : null}
                  </td>
                  <td><code>{formatValue(row.default)}</code></td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ))}
    </>
  );
}

export function NextDocView({ page }: { page: NextDocPage }) {
  return (
    <>
      <DocsHeading level={1} id="title">{page.title}</DocsHeading>
      {page.slug === "getting-started" ? null : <p><em>{page.description}</em></p>}
      {page.body.map((block, index) => <Block key={index} block={block} />)}
      {page.slug === "keyboard-shortcuts" ? <p><Link href="/docs/keyboard-shortcuts">Open the keyboard shortcuts list</Link></p> : null}
      {page.generated === "cli" ? <CliTables /> : null}
      {page.generated === "settings" ? <SettingsTables /> : null}
    </>
  );
}
