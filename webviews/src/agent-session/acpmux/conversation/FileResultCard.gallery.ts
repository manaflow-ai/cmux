// l10n-allow-file: gallery fixtures, not shipped UI.
// An opened read or file search draws what it found (FileResultCard.tsx; Leo, 2026-11-05: "could we
// potentially do even better?"). References: claude/web/web-session-tool-transcript (Grep and Read
// rows, one line each), cursor/live/agent-tool-search-running ("Exploring 4 files, 1 search"). The
// closed row stays one line; opened, a Read is the edit card's frame over its numbered lines, and a
// search is its counts over each file and its matching lines. Two alternatives are drawn for comparison.
import type { Play } from "../../../gallery/play";
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";

const FILE = "/work/storefront/app/layout.tsx";
const SOURCE = [
  'import type { ReactNode } from "react";',
  'import { Inter } from "next/font/google";',
  'import "./globals.css";',
  "",
  'const inter = Inter({ subsets: ["latin"] });',
  "",
  "export default function RootLayout({ children }: { children: ReactNode }) {",
  "  const year = new Date().getFullYear();",
  "  return (",
  '    <html lang="en">',
  "      <body className={inter.className}>",
  "        {children}",
  "        <footer>© {year} Storefront</footer>",
  "      </body>",
  "    </html>",
  "  );",
  "}",
];
const numbered = (lines: string[], start: number) =>
  lines.map((line, index) => `${String(start + index).padStart(6)}→${line}`).join("\n");

const read = () =>
  tool("Read layout.tsx", "read", "completed", {
    inputSummary: JSON.stringify({ file_path: FILE, offset: 1, limit: 40 }),
    locations: [{ path: FILE }],
    output: numbered(SOURCE, 1),
  });

const grep = () =>
  tool("Grep new Date\\(", "read", "completed", {
    inputSummary: JSON.stringify({
      pattern: "new Date\\(",
      path: "app",
      output_mode: "content",
      "-n": true,
    }),
    output: [
      "/work/storefront/app/layout.tsx:8:  const year = new Date().getFullYear();",
      "/work/storefront/app/page.tsx:14:  const today = new Date().toLocaleDateString();",
      "/work/storefront/app/page.tsx:31:      <time>{new Date(post.date).toLocaleDateString()}</time>",
      "/work/storefront/app/lib/format.ts:3:export const stamp = () => new Date().toISOString();",
    ].join("\n"),
  });

const glob = () =>
  tool("Glob app/**/*.tsx", "read", "completed", {
    inputSummary: JSON.stringify({ pattern: "app/**/*.tsx" }),
    output: [
      "/work/storefront/app/layout.tsx",
      "/work/storefront/app/page.tsx",
      "/work/storefront/app/blog/page.tsx",
      "/work/storefront/app/blog/[slug]/page.tsx",
      "/work/storefront/app/components/Footer.tsx",
    ].join("\n"),
  });

const openAll: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("button.cv-tool"));
  for (const button of ctx.document.querySelectorAll<HTMLButtonElement>("button.cv-tool")) button.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-filepeek, .cv-filematches"));
};

const restyled =
  (css: string): Play =>
  async (ctx) => {
    const style = ctx.document.createElement("style");
    style.textContent = css;
    ctx.document.head.append(style);
    await openAll(ctx);
  };

const turn = (calls: ReturnType<typeof tool>[]) =>
  chat([
    user("Why does the landing page log a hydration warning?", 3),
    ...calls.map((call) => activity([call], 2)),
    assistant("The footer's year and the post dates render with the server's clock.", 1),
  ]);

export default agentPaneEntry({
  id: "agent-pane.file-result-cards",
  title: "Read, Grep and Glob results as cards",
  area: "Agent pane",
  height: 900,
  covers: [
    "agent-session/acpmux/conversation/FileResultCard.tsx",
    "agent-session/acpmux/conversation/fileResults.ts",
    "agent-session/acpmux/conversation/ToolRow.tsx",
  ],
  variants: {
    closed: {
      note: "Closed, each call stays one transcript row; a click or tap opens its card.",
      snapshot: turn([read(), grep(), glob()]),
    },
    cards: {
      note: "Selected: opened. The Read is the edit card's frame (file name, Lines 1–17, copy) over its highlighted lines numbered from where it read, cut to eight under a fade with Show all. The Grep counts its matches and files, then each file and its lines, number first; the Glob lists its files. A name or a line opens the file in cmux.",
      snapshot: turn([read(), grep(), glob()]),
      play: openAll,
    },
    "search-in-card": {
      note: "Alternative: the search's files inside the same filled card as the Read. Matches the Read, but a run of searches becomes a stack of boxes, which the transcript spec avoids for steps.",
      snapshot: turn([grep(), glob()]),
      play: restyled(
        ".cv-filematches { padding: 8px 12px; border-radius: 12px; background: var(--cv-codeblock-bg); box-shadow: inset 0 0 0 1px var(--cv-codeblock-ring); }",
      ),
    },
    "read-no-gutter": {
      note: "Alternative: the Read without line numbers. Quieter, but a read from line 120 no longer says where its lines are.",
      snapshot: turn([read()]),
      play: restyled(
        ".cv-filepeek__gutter { display: none; } .cv-filepeek__lines .cv-code-plain { padding-left: 12px; }",
      ),
    },
  },
});
