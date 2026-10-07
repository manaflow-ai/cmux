// l10n-allow-file: gallery fixtures (sample documents), not shipped UI.
// The markdown editor page (cmux-page://cmux.markdown/) on fixed files: the real page entry
// (main.tsx) over an in-page cmuxPage host (src/gallery/frame/pages.ts).
import { markdownPageEntry } from "../../gallery/format";

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

export default markdownPageEntry({
  id: "pages.markdown",
  title: "Markdown editor",
  area: "Pages",
  height: 640,
  covers: ["page:cmux.markdown", "pages/markdown/MarkdownPage.tsx", "viewer-empty/MarkdownEmptyState.tsx"],
  variants: {
    readme: {
      note: "A README: headings, a table, code, a task list, math, links.",
      path: "/Users/you/src/atlas-web/README.md",
      text: README,
      files: { "/Users/you/src/atlas-web/notes.md": "# Notes\n\nPorts: 5173, 8080.\n" },
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
