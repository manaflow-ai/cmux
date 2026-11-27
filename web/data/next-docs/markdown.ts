// Plain Markdown for a hand-written cmux-next docs page, rendered from the same
// blocks the site renders (pages.ts). The Start page's copy lives in the repo at
// docs/cmux-next/start.md so an agent can read it at a public URL today:
// cmux.com/docs/nightly/next/* is served by the nightly docs zone, which is built
// from main, where these pages do not exist. web/scripts/export-next-start.ts
// writes that file; web/tests/next-docs.test.ts fails when it drifts.
import { nextDocPage, type DocBlock, type NextDocPage } from "./pages";

/** The repository path of the Start page's Markdown copy. */
export const NEXT_START_MARKDOWN_PATH = "docs/cmux-next/start.md";

/** Where anyone, signed in or not, reads that copy: the public repository's raw file on feat-cmux-next. */
export const NEXT_START_MARKDOWN_URL = `https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/${NEXT_START_MARKDOWN_PATH}`;

function fence(code: string, lang?: string): string {
  const longest = Math.max(2, ...(code.match(/`+/g) ?? []).map((run) => run.length));
  const ticks = "`".repeat(longest + 1);
  return `${ticks}${lang ?? ""}\n${code}\n${ticks}`;
}

function block(item: DocBlock): string {
  if ("h2" in item) return `## ${item.h2}`;
  if ("p" in item) return item.p;
  if ("note" in item) return `> ${item.note}`;
  if ("ul" in item) return item.ul.map((line) => `- ${line}`).join("\n");
  if ("ol" in item) return item.ol.map((line, index) => `${index + 1}. ${line}`).join("\n");
  if ("code" in item) return fence(item.code, item.lang);
  // The architecture diagram is drawn only on the web page; as text it is its caption (as next-docs-text.ts).
  if ("diagram" in item) return item.caption;
  return item.files
    .map((file) => `- [${file.path}](https://github.com/manaflow-ai/cmux/${file.kind === "file" ? "blob" : "tree"}/feat-cmux-next/${file.path}): ${file.what}`)
    .join("\n");
}

/** A page as Markdown: title, description, then each block in order. */
export function nextDocMarkdown(page: NextDocPage, header: string[] = []): string {
  const parts = [`# ${page.title}`, page.description, ...header, ...page.body.map(block)];
  return `${parts.join("\n\n")}\n`;
}

/** docs/cmux-next/start.md, byte for byte. */
export function nextStartMarkdown(): string {
  const page = nextDocPage("start");
  if (!page) throw new Error("next-docs: no start page");
  return nextDocMarkdown(page, [
    "<!-- Generated from web/data/next-docs/pages.ts by `bun web/scripts/export-next-start.ts`. Edit pages.ts, not this file. -->",
    "> If you are an agent and a person pointed you at this page: do the steps under \"If you are an agent\" below, in order, on their Mac.",
  ]);
}
