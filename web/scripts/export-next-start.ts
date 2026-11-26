// Writes docs/cmux-next/start.md, the Start page (web/data/next-docs/pages.ts)
// as Markdown, so the one-line setup prompt points an agent at a URL that
// serves today (web/data/next-docs/markdown.ts says why). Run it after editing
// the Start page; web/tests/next-docs.test.ts fails while the file is stale.
//   bun web/scripts/export-next-start.ts
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { NEXT_START_MARKDOWN_PATH, nextStartMarkdown } from "../data/next-docs/markdown";

const repo = fileURLToPath(new URL("../..", import.meta.url));
writeFileSync(join(repo, NEXT_START_MARKDOWN_PATH), nextStartMarkdown());
console.log(`wrote ${NEXT_START_MARKDOWN_PATH}`);
