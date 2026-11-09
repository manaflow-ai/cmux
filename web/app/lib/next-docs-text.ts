import { nextDocPage, nextDocPages, nextDocPublicPath, repoSourceHref, type NextDocPage } from "../../data/next-docs/pages";

// The cmux-next pages as Markdown, built from the same page data the HTML pages render, so they
// cannot drift from them. Two copies: llms-full.txt on the site (links are URLs), and the local
// guide in docs/cmux-next/guide (links are files and `cmux docs guide` commands), which the cmux
// CLI embeds so an agent reads the docs with no network (`cmux docs guide`).
// The generated reference tables (CLI, palette, settings) are not inlined: the site links its own
// page, and the local guide names the command that prints the same table.

type Links = {
  /** Where a page's own address is, or null for none. */
  self: (slug: string) => string | null;
  /** A link to another page. */
  page: (slug: string) => string;
  /** The line a generated reference page adds after its body. */
  generated: (page: NextDocPage) => string;
};

const localTableCommand: Record<NonNullable<NextDocPage["generated"]>, string> = {
  cli: "`cmux --help`, `cmux <scope> --help` and `cmux action list`",
  palette: "`cmux action list`",
  shortcuts: "`cmux keybinding list`",
  settings: "`cmux settings get`",
};

function pageMarkdown(page: NextDocPage, links: Links): string {
  const self = links.self(page.slug);
  const lines = [`# ${page.title}`, "", ...(self ? [`URL: ${self}`, ""] : []), page.description, ""];
  for (const block of page.body) {
    if ("h2" in block) lines.push(`## ${block.h2}`, "");
    else if ("p" in block) lines.push(block.p, "");
    else if ("note" in block) lines.push(`> ${block.note}`, "");
    else if ("ul" in block) lines.push(...block.ul.map((item) => `- ${item}`), "");
    else if ("code" in block) lines.push(`\`\`\`${block.lang ?? "bash"}`, block.code, "```", "");
    else if ("diagram" in block) lines.push(block.caption, "");
    else lines.push("| Where | What |", "| --- | --- |", ...block.files.map((file) => `| [\`${file.path}\`](${repoSourceHref(file.path)}) | ${file.what} |`), "");
  }
  if (page.generated) lines.push(links.generated(page), "");
  for (const slug of page.links ?? []) {
    const target = nextDocPage(slug);
    if (target) lines.push(`- [${target.title}](${links.page(slug)})`);
  }
  return lines.join("\n").trimEnd() + "\n";
}

function siteLinks(origin: string): Links {
  return {
    self: (slug) => `${origin}${nextDocPublicPath(slug)}`,
    page: (slug) => `${origin}${nextDocPublicPath(slug)}.md`,
    generated: (page) => `The full table is at ${origin}${nextDocPublicPath(page.slug)}.md`,
  };
}

const localLinks: Links = {
  self: () => null,
  page: (slug) => `${slug}.md`,
  generated: (page) => `The full table is generated from the app's own catalog. In a cmux terminal, ${localTableCommand[page.generated!]} print it.`,
};

const fullHeader = (lead: string) => ["# cmux NEXT documentation", "", `> ${lead}`].join("\n");

export function buildNextDocsFullText(origin: string): string {
  const header = fullHeader("Every cmux NEXT docs page in full. Each page is also served alone as Markdown at its URL plus .md. In a cmux terminal, `cmux docs guide` prints these pages, `cmux --help` and `cmux skill show` describe the CLI, and `cmux docs search` searches its commands.");
  return [header, ...nextDocPages.map((page) => pageMarkdown(page, siteLinks(origin)).trimEnd())].join("\n\n---\n\n") + "\n";
}

/** One page of the local guide, as the cmux CLI embeds it (docs/cmux-next/guide/pages.json). */
export interface LocalGuidePage {
  slug: string;
  title: string;
  description: string;
  markdown: string;
}

/**
 * The local guide: file name to contents, for docs/cmux-next/guide. `cmux docs guide` reads
 * pages.json; the .md files, llms.txt and llms-full.txt are the same pages for agents and people
 * reading the repository.
 */
export function buildLocalGuide(): Record<string, string> {
  const pages: LocalGuidePage[] = nextDocPages.map((page) => ({
    slug: page.slug,
    title: page.title,
    description: page.description,
    markdown: pageMarkdown(page, localLinks),
  }));
  const files: Record<string, string> = {};
  for (const page of pages) files[`${page.slug}.md`] = page.markdown;
  files["llms.txt"] = [
    "# cmux NEXT guide",
    "",
    "> How cmux NEXT works and how to use it, one Markdown file per page. Generated from web/data/next-docs/pages.ts by `bun web/scripts/export-next-docs.ts`; do not edit. In a cmux terminal, `cmux docs guide` lists these pages and `cmux docs guide SLUG` prints one.",
    "",
    "## Pages",
    "",
    ...pages.map((page) => `- [${page.title}](${page.slug}.md): ${page.description}`),
    "",
    "## Everything in one file",
    "",
    "- [llms-full.txt](llms-full.txt)",
    "",
  ].join("\n");
  files["llms-full.txt"] = [
    fullHeader("Every cmux NEXT guide page in full. In a cmux terminal, `cmux docs guide --full` prints this file, `cmux --help` and `cmux skill show` describe the CLI, and `cmux docs search` searches its commands."),
    ...pages.map((page) => page.markdown.trimEnd()),
  ].join("\n\n---\n\n") + "\n";
  files["pages.json"] = JSON.stringify({ version: 1, pages }, null, 2) + "\n";
  return files;
}
