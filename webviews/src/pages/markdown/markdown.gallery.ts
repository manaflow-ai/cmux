// l10n-allow-file: gallery fixtures (sample documents), not shipped UI.
// The markdown editor page (cmux-page://cmux.markdown/) on fixed files: the real page entry
// (main.tsx) over an in-page cmuxPage host (src/gallery/frame/pages.ts).
import { markdownPageEntry } from "../../gallery/format";
import SHOWCASE from "../../gallery/fixtures/markdown-showcase.md?raw";
// The user's five table cases (MARKDOWN-TABLE-SCROLL, test/markdown-table-scroll-cases.test.ts).
import TABLE_SCROLL_CASES from "../../gallery/fixtures/markdown-table-scroll-cases.md?raw";
import SHOWCASE_SVG from "../../gallery/fixtures/markdown-showcase-assets/sample.svg?raw";

const README = `# Atlas web

The web client for **Atlas**: a small app that shows how cmux pages render.

## Setup

1. Install [Bun](https://bun.sh).
2. Run \`bun install\`, then \`bun run dev\`.

> The dev server listens on port 5173. See [the notes](notes.md) for the ports of the other services.

## Retry policy

| Status | Retried | Note |
| --- | --- | --- |
| 408 | yes | request timeout |
| 429 | yes | rate limited |
| 500 | no | a server bug |

\`\`\`ts
export async function withRetry<T>(task: () => Promise<T>, attempts = 3): Promise<T> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await task();
    } catch (error) {
      if (attempt >= attempts) throw error;
    }
  }
}
\`\`\`

- [x] Retries for GETs
- [ ] A circuit breaker
- [ ] Docs for the POST rule

The expected wait is $E[W] = \\sum_{n=1}^{N-1} d_0 2^{n-1}$.

Track the related fixes in #18325 and manaflow-ai/cmux#18321.
`;

const LONG = Array.from(
  { length: 40 },
  (_, index) =>
    `## Section ${index + 1}\n\nParagraph ${index + 1}: a long document so the outline, the scroll position and the sticky toolbar have work to do. ${"More text follows. ".repeat(6)}\n`,
).join("\n");

const FRONTMATTER = `---
title: Release notes
version: 0.42.0
tags: [release, notes]
---

# 0.42.0

- **Added** the gallery.
- **Fixed** a crash when a tab closed during a drag.
`;

// A table and a code line far wider than the column (MARKDOWN-TABLE-SCROLL): each scrolls sideways
// in its own box while the page scrolls only up and down (test/markdown-wide-table-scroll.test.ts).
const WIDE_TABLE = `# Release matrix

${"The table below is wider than the reading column. ".repeat(3)}

| ${Array.from({ length: 14 }, (_, index) => `Column ${index + 1}`).join(" | ")} |
| ${Array.from({ length: 14 }, () => "---").join(" | ")} |
${Array.from(
  { length: 6 },
  (_, row) =>
    `| ${Array.from({ length: 14 }, (_, column) => `value ${row + 1}.${column + 1} with words`).join(" | ")} |`,
).join("\n")}

\`\`\`ts
export const WIDE_LINE = "${"a long code line that does not wrap ".repeat(8)}";
\`\`\`

${Array.from({ length: 30 }, (_, index) => `Paragraph ${index + 1} so the page itself scrolls up and down.`).join("\n\n")}
`;

// A small table for selection, keys, column resizing and border compositing
// (test/markdown-table-obsidian.test.ts, MARKDOWN-OBSIDIAN-PARITY).
const TABLE_EDITING = `# Team

| Name | Role | Team |
| --- | :---: | ---: |
| Ada | Engineer | Core |
| Grace | Admiral | Navy |
| Linus | Maintainer | Kernel |

After the table.
`;

// Obsidian's syntax, drawn Live Preview style (test/markdown-obsidian-syntax.test.ts).
const OBSIDIAN = `# Obsidian syntax

Some ==highlighted words==, a %%hidden comment%%, tags #project/alpha and #todo, and links to
[[Project Plan]] and [[notes/ideas#Next|the ideas]].

> [!note] A note callout
> Callouts take a type and an optional title.

> [!warning]
> No title: the type is the title.

> [!tip]- Folded at first
> Click the chevron to open it.

Energy is $E = mc^2$, and the sum is:

$$
\\sum_{n=1}^{N} n = \\frac{N(N+1)}{2}
$$

- [x] Done
- [ ] Open
`;

// Text selection over every kind of block (test/markdown-selection.test.ts, MARKDOWN-SELECTION): a
// drag across paragraphs, highlights, math, a list, a table, code and a diagram keeps the text
// under the pointer where it is, and a reload from disk keeps the selection on the same words.
const SELECTION = `# Selection guide

First paragraph with a [docs link](https://example.com/docs) and **bold words** in it.

Second paragraph with ==highlighted words== and the formula $E = mc^2$ inline.

- First list item
- Second list item

| Name | Role |
| --- | --- |
| Ada | Engineer |

\`\`\`ts
const answer = 42;
\`\`\`

\`\`\`mermaid
graph LR
  A --> B
\`\`\`

## Closing heading

Last paragraph ends the guide.
`;

const REMOTE_IMAGES = `# Web images

Remote images stay private until you choose to load them.

![Build status](https://images.example.test/build-status.png)

<img src="https://images.example.test/architecture.png" alt="Architecture diagram">
`;

const TASK_CHECKED = "- [x] Checked task\n- [x] Another completed task\n";
const TASK_UNCHECKED = "- [ ] Unchecked task\n- [ ] Follow-up still needed\n";
const TASK_NESTED =
  "- [x] Release checklist\n  - [ ] Update the changelog\n  - [x] Run the focused tests\n    - [ ] Ask for review\n";
const TASK_LONG = `- [ ] This task has a deliberately long title that wraps across several lines in a narrow markdown column so the checkbox stays aligned with the first line of the item rather than drifting into the line box.`;

const SHOWCASE_DIR = "/Users/you/src/markdown-showcase";

/// The showcase split at its level-2 headings (outside code fences), one variant per section,
/// with stable ids from the heading text so a section keeps its URL.
function showcaseSections(text: string): Array<{ id: string; title: string; body: string }> {
  const lines = text.split("\n");
  const sections: Array<{ id: string; title: string; body: string }> = [];
  let fence: string | null = null;
  let current: { title: string; lines: string[] } | null = null;
  for (const line of lines) {
    const marker = /^\s*(`{3,}|~{3,})/.exec(line)?.[1];
    if (marker) fence = fence === null ? marker[0] : marker[0] === fence ? null : fence;
    if (fence === null && line.startsWith("## ") && !marker) {
      if (current) sections.push({ id: "", title: current.title, body: current.lines.join("\n") });
      current = { title: line.slice(3).trim(), lines: [line] };
    } else current?.lines.push(line);
  }
  if (current) sections.push({ id: "", title: current.title, body: current.lines.join("\n") });
  return sections.map((section) => ({
    ...section,
    id: `showcase-${section.title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "")}`,
  }));
}

const showcaseFiles = { [`${SHOWCASE_DIR}/markdown-showcase-assets/sample.svg`]: SHOWCASE_SVG };
const showcaseVariants = Object.fromEntries(
  showcaseSections(SHOWCASE).map((section) => [
    section.id,
    {
      note: `Showcase section: ${section.title}.`,
      path: `${SHOWCASE_DIR}/markdown-showcase.md`,
      text: section.body,
      files: showcaseFiles,
    },
  ]),
);

export default markdownPageEntry({
  id: "pages.markdown",
  title: "Markdown editor",
  area: "Pages",
  height: 640,
  covers: [
    "page:cmux.markdown",
    "pages/markdown/MarkdownPage.tsx",
    // The toolbar's Aa button opens it on every variant; its text width row is WidthField.
    "pages/markdown/ReadingSettings.tsx",
    "pages/markdown/WidthField.tsx",
    "viewer-empty/MarkdownEmptyState.tsx",
  ],
  variants: {
    showcase: {
      note: "The full markdown showcase (every feature the agent replies must render).",
      path: `${SHOWCASE_DIR}/markdown-showcase.md`,
      text: SHOWCASE,
      files: showcaseFiles,
    },
    ...showcaseVariants,
    readme: {
      note: "A README: headings, a table, code, a task list, math, links.",
      path: "/Users/you/src/atlas-web/README.md",
      text: README,
      githubRepository: "manaflow-ai/cmux",
      files: { "/Users/you/src/atlas-web/notes.md": "# Notes\n\nPorts: 5173, 8080.\n" },
    },
    find: {
      note: "Cmd-F: the find pill over the document, every match highlighted, the active one apart.",
      path: "/Users/you/src/atlas-web/README.md",
      text: README,
      githubRepository: "manaflow-ai/cmux",
      find: "retr",
    },
    "github-references": {
      note: "Bare and qualified GitHub references link in the rich viewer; code remains literal.",
      path: "/Users/you/src/atlas-web/REFERENCES.md",
      text: "# Review links\n\nFollow #18325 and manaflow-ai/cmux#18321.\n\n`#18325`\n\n```text\n#18321\n```\n",
      githubRepository: "manaflow-ai/cmux",
    },
    "edit-cue-rich": {
      note: "Chosen version: the default rich editor has a compact Edit button beside its save status.",
      path: "/Users/you/src/atlas-web/README.md",
      text: README,
    },
    "edit-cue-source": {
      note: "Comparison version: source mode keeps the existing Rich text / Source toggle while editing.",
      path: "/Users/you/src/atlas-web/README.md",
      text: README,
      settings: { defaultMode: "source" },
    },
    // The link editor (Cmd-K, or Edit link in the bubble): a liquid glass popover whose one edge is
    // the glass rim (test/glass-one-edge.test.ts).
    "link-editor": {
      note: "The link editor popover, open on a link: Text, URL, Remove and Apply.",
      path: "/Users/you/src/atlas-web/LINKS.md",
      text: "# Links\n\nRead the [docs link](https://example.com/docs) before you start.\n",
      play: async (ctx) => {
        await ctx.click({ text: "docs link" });
        await ctx.click({ role: "button", name: "Edit link" });
      },
    },
    "tasks-checked": {
      note: "Checked task-list items.",
      path: "/Users/you/src/atlas-web/TASKS.md",
      text: TASK_CHECKED,
    },
    "tasks-unchecked": {
      note: "Unchecked task-list items.",
      path: "/Users/you/src/atlas-web/TASKS.md",
      text: TASK_UNCHECKED,
    },
    "tasks-nested": {
      note: "Nested checked and unchecked task-list items.",
      path: "/Users/you/src/atlas-web/TASKS.md",
      text: TASK_NESTED,
    },
    "tasks-long": {
      note: "A long task-list item wrapping in a narrow column.",
      path: "/Users/you/src/atlas-web/TASKS.md",
      text: TASK_LONG,
    },
    "read-only": {
      note: "A file the user cannot write.",
      path: "/Users/you/src/atlas-web/README.md",
      text: README,
      readOnly: true,
    },
    frontmatter: {
      note: "YAML front matter over the body.",
      path: "/Users/you/src/atlas-web/RELEASE.md",
      text: FRONTMATTER,
    },
    "wide-table": {
      note: "A table and a code line wider than the column: each scrolls sideways on its own.",
      path: "/Users/you/src/atlas-web/MATRIX.md",
      text: WIDE_TABLE,
    },
    "table-scroll": {
      note: "Five tables: 20 columns, a long cell and code cells scroll sideways; 40 rows and a small table fit.",
      path: "/Users/you/fun/markdown-table-scroll-test.md",
      text: TABLE_SCROLL_CASES,
    },
    "table-editing": {
      note: "A small table: cell selection, Tab and Return, column resizing.",
      path: "/Users/you/src/atlas-web/TEAM.md",
      text: TABLE_EDITING,
    },
    obsidian: {
      note: "Obsidian syntax: highlights, comments, tags, wikilinks, callouts, math.",
      path: "/Users/you/src/atlas-web/VAULT.md",
      text: OBSIDIAN,
    },
    selection: {
      note: "Text selection across paragraphs, highlights, math, a list, a table, code and a diagram.",
      path: "/Users/you/src/atlas-web/SELECTION.md",
      text: SELECTION,
    },
    "remote-images-blocked": {
      note: "Web images before this document receives reader approval.",
      path: "/Users/you/src/atlas-web/REMOTE-IMAGES.md",
      text: REMOTE_IMAGES,
    },
    long: {
      note: "A long document (40 sections).",
      path: "/Users/you/src/atlas-web/GUIDE.md",
      text: LONG,
    },
    empty: {
      note: "No file: the empty state with recent files.",
      path: "",
      text: null,
      files: {
        "/Users/you/src/atlas-web/README.md": README,
        "/Users/you/src/atlas-web/notes.md": "# Notes\n",
        "/Users/you/src/cmux/CHANGELOG.md": "# Changelog\n",
      },
    },
  },
});
