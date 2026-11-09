import { nextDocPage, nextDocPages, nextDocPublicPath, repoSourceHref, type NextDocPage } from "../../data/next-docs/pages";

// llms-full.txt: every cmux-next page in full, as one Markdown file, for agents that read the docs
// in one fetch. Built from the same page data the HTML pages render, so it cannot drift from them.
// The generated reference tables (CLI, palette, settings) are linked, not inlined: each is its own
// page with a .md variant.

function pageMarkdown(page: NextDocPage, origin: string): string {
  const lines = [`# ${page.title}`, "", `URL: ${origin}${nextDocPublicPath(page.slug)}`, "", page.description, ""];
  for (const block of page.body) {
    if ("h2" in block) lines.push(`## ${block.h2}`, "");
    else if ("p" in block) lines.push(block.p, "");
    else if ("note" in block) lines.push(`> ${block.note}`, "");
    else if ("ul" in block) lines.push(...block.ul.map((item) => `- ${item}`), "");
    else if ("code" in block) lines.push(`\`\`\`${block.lang ?? "bash"}`, block.code, "```", "");
    else if ("diagram" in block) lines.push(block.caption, "");
    else lines.push("| Where | What |", "| --- | --- |", ...block.files.map((file) => `| [\`${file.path}\`](${repoSourceHref(file.path)}) | ${file.what} |`), "");
  }
  if (page.generated) lines.push(`The full table is at ${origin}${nextDocPublicPath(page.slug)}.md`, "");
  for (const slug of page.links ?? []) {
    const target = nextDocPage(slug);
    if (target) lines.push(`- [${target.title}](${origin}${nextDocPublicPath(slug)}.md)`);
  }
  return lines.join("\n").trimEnd();
}

export function buildNextDocsFullText(origin: string): string {
  const header = [
    "# cmux NEXT documentation",
    "",
    "> Every cmux NEXT docs page in full. Each page is also served alone as Markdown at its URL plus .md. In a cmux terminal, `cmux --help` and `cmux skill show` describe the CLI, and `cmux docs` searches its commands.",
  ].join("\n");
  return [header, ...nextDocPages.map((page) => pageMarkdown(page, origin))].join("\n\n---\n\n") + "\n";
}
