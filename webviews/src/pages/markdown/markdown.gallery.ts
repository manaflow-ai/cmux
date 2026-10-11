// l10n-allow-file: gallery fixtures (sample documents), not shipped UI.
// The markdown editor page (cmux-page://cmux.markdown/) on fixed files: the real page entry
// (main.tsx) over an in-page cmuxPage host (src/gallery/frame/pages.ts).
import { markdownPageEntry } from "../../gallery/format";
import SHOWCASE from "../../gallery/fixtures/markdown-showcase.md?raw";
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
  covers: ["page:cmux.markdown", "pages/markdown/MarkdownPage.tsx", "viewer-empty/MarkdownEmptyState.tsx"],
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
    "github-references": {
      note: "Bare and qualified GitHub references link in the rich viewer; code remains literal.",
      path: "/Users/you/src/atlas-web/REFERENCES.md",
      text: "# Review links\n\nFollow #18325 and manaflow-ai/cmux#18321.\n\n`#18325`\n\n```text\n#18321\n```\n",
      githubRepository: "manaflow-ai/cmux",
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
