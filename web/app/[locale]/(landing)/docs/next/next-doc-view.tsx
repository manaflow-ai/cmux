import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";
import cliReference from "@/data/next-docs/cli-reference.generated.json";
import paletteReference from "@/data/next-docs/palette-reference.generated.json";
import settingsReference from "@/data/next-docs/settings-reference.generated.json";
import type { CliReference, PaletteReference, SettingsReference } from "@/scripts/export-next-docs";
import {
  headingId,
  nextDocHref,
  nextDocPage,
  nextDocPublicPath,
  type DocBlock,
  type NextDocPage,
} from "@/data/next-docs/pages";
import { baseDocsLocales } from "@/app/[locale]/components/docs-nav-items";
import { docsChannel } from "@/app/lib/docs-channel";
import { buildAlternates } from "@/i18n/seo";
import { DocsSchema } from "../docs-schema";

/** Where this docs channel serves a cmux-next page: the nightly zone's public path, else /docs/next. */
function nextDocChannelPath(slug: string): string {
  return docsChannel() === "nightly" ? nextDocPublicPath(slug) : nextDocHref(slug);
}

/**
 * Metadata of a cmux-next page: its nightly URL is canonical, the one place it is served. The
 * pages are English only, so a page served under another locale (see `NextDocView`) names the
 * English URL as canonical.
 */
export function nextDocMetadata(page: NextDocPage, locale: string) {
  const english = baseDocsLocales.includes(locale as (typeof baseDocsLocales)[number]) ? locale : "en";
  return {
    title: page.title,
    description: page.description,
    alternates: buildAlternates(english, nextDocChannelPath(page.slug), baseDocsLocales),
  };
}

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
        {reference.counts.verbs} commands, {reference.counts.mcp} of them also MCP tools. The MCP column
        gives the tool name that <code>cmux mcp serve --all-tools</code> offers.
      </p>
      {reference.nouns.map((entry) => (
        <section key={entry.noun}>
          <DocsHeading level={2} id={`cmux-${entry.noun}`}>{`cmux ${entry.noun}`}</DocsHeading>
          <table>
            <thead>
              <tr><th>Command</th><th>What it does</th><th>MCP tool</th></tr>
            </thead>
            <tbody>
              {entry.verbs.map((verb) => (
                <tr key={verb.id}>
                  <td><code>{verb.command}</code></td>
                  <td>{verb.title}</td>
                  <td>{verb.mcpTool ? <code>{verb.mcpTool}</code> : "no"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ))}
    </>
  );
}

function PaletteTables({ shortcutsOnly }: { shortcutsOnly: boolean }) {
  const reference = paletteReference as PaletteReference;
  const sections = reference.sections
    .map((section) => ({ ...section, entries: shortcutsOnly ? section.entries.filter((entry) => entry.shortcut) : section.entries }))
    .filter((section) => section.entries.length > 0);
  return (
    <>
      <p>
        {shortcutsOnly
          ? `${reference.counts.shortcuts} default shortcuts.`
          : `${reference.counts.entries} commands in the palette, ${reference.counts.shortcuts} with a default shortcut.`}
      </p>
      {sections.map((section) => (
        <section key={section.id}>
          <DocsHeading level={2} id={section.id.replace(/^category\./, "")}>{section.title}</DocsHeading>
          <table>
            <thead>
              <tr><th>Command</th><th>Shortcut</th>{shortcutsOnly ? null : <th>CLI</th>}</tr>
            </thead>
            <tbody>
              {section.entries.map((entry) => (
                <tr key={entry.id}>
                  <td>{entry.title}</td>
                  <td>{entry.shortcut ? <kbd>{entry.shortcut}</kbd> : null}</td>
                  {shortcutsOnly ? null : <td>{entry.command ? <code>{entry.command}</code> : null}</td>}
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

/**
 * A cmux-next page. The pages are English only, but a reader whose NEXT_LOCALE cookie or
 * Accept-Language picks another locale is sent to /<locale>/docs/next/... by locale negotiation,
 * and that route used to 404. A redirect back to the unprefixed URL would only be negotiated to
 * the locale again, so every locale serves the English page, with the English URL as canonical
 * (`nextDocMetadata`). The docs layout marks the body `lang="en"` on its `.docs-content`
 * (`docsContentLang`): the blocks below stay its direct children, which globals.css styles.
 */
export function NextDocView({ page }: { page: NextDocPage }) {
  return (
    <>
      <DocsSchema title={page.title} path={nextDocChannelPath(page.slug)} />
      <DocsHeading level={1} id="title">{page.title}</DocsHeading>
      {page.slug === "getting-started" ? null : <p><em>{page.description}</em></p>}
      {page.body.map((block, index) => <Block key={index} block={block} />)}
      {page.links ? (
        <ul>
          {page.links.map((slug) => {
            const target = nextDocPage(slug);
            return target ? <li key={slug}><Link href={nextDocHref(slug)}>{target.title}</Link></li> : null;
          })}
        </ul>
      ) : null}
      {page.generated === "cli" ? <CliTables /> : null}
      {page.generated === "settings" ? <SettingsTables /> : null}
      {page.generated === "palette" ? <PaletteTables shortcutsOnly={false} /> : null}
      {page.generated === "shortcuts" ? <PaletteTables shortcutsOnly /> : null}
    </>
  );
}
