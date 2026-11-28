// l10n-allow-file: gallery fixtures (sample replies), not shipped UI.
// Audit (Leo 2026-11-22: "we need to audit our other possible renderings"): every rich block a reply
// can carry, each narrower than the column, beside a centered table, so their alignment, spacing and
// theme read side by side; and long unbroken strings in every prose context.
import { agentPaneEntry, type ChipHostFixture } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const svg = (markup: string) => `data:image/svg+xml;base64,${btoa(markup)}`;
const SMALL = "/Users/you/src/atlas-web/shots/badge.png";
const HOST: ChipHostFixture = {
  paths: { [SMALL]: { place: "root", folder: false } },
  images: {
    [SMALL]: svg(
      '<svg xmlns="http://www.w3.org/2000/svg" width="240" height="140"><rect width="240" height="140" fill="#ffffff"/><rect x="20" y="20" width="200" height="100" rx="12" fill="#3b6fd8"/><text x="120" y="78" font-family="sans-serif" font-size="22" fill="#fff" text-anchor="middle">badge 240x140</text></svg>',
    ),
  },
  policy: { outsideRoots: "confirm", remoteImages: "click" },
};

const fence = (lang: string, code: string) => "```" + lang + "\n" + code + "\n```";

const MIX = [
  "A short table, for reference:",
  "",
  "| Step | ms |",
  "| --- | --- |",
  "| parse | 12 |",
  "| draw | 30 |",
  "",
  "A short mermaid diagram:",
  "",
  fence("mermaid", "flowchart LR\n  A[Request] --> B{Cached?}\n  B -->|yes| C[Serve]\n  B -->|no| D[Fetch]"),
  "",
  "A small vega-lite chart:",
  "",
  fence(
    "vega-lite",
    JSON.stringify({
      $schema: "https://vega.github.io/schema/vega-lite/v5.json",
      width: 200,
      height: 100,
      data: {
        values: [
          { k: "a", v: 3 },
          { k: "b", v: 7 },
          { k: "c", v: 5 },
        ],
      },
      mark: "bar",
      encoding: { x: { field: "k", type: "nominal" }, y: { field: "v", type: "quantitative" } },
    }),
  ),
  "",
  "A pie chart fence:",
  "",
  fence(
    "chart",
    JSON.stringify({
      type: "pie",
      data: [
        { k: "build", v: 60 },
        { k: "test", v: 30 },
        { k: "lint", v: 10 },
      ],
      x: "k",
      y: "v",
    }),
  ),
  "",
  "Display math:",
  "",
  "$$a^2 + b^2 = c^2$$",
  "",
  "A narrow image:",
  "",
  `![badge](${SMALL})`,
  "",
  "> A blockquote that says one short thing.",
  "",
  "A short code block:",
  "",
  fence("ts", "const x = 1;"),
  "",
  "The end.",
].join("\n");

const TOKEN = "a1b2c3d4e5".repeat(20);
const URL = `https://example.test/research/2026/agent-session/gallery/fixtures/${"segment-".repeat(26)}end?view=transcript&sort=recent&q=${"x".repeat(40)}`;

const LONG = [
  `## Heading with ${TOKEN}`,
  "",
  `Prose with a long URL ${URL} and then more words after it.`,
  "",
  `Prose with a long token ${TOKEN} and then more words.`,
  "",
  `Inline code: \`${TOKEN}\` then words.`,
  "",
  `- A list item with ${TOKEN}`,
  `- A list item with a link ${URL}`,
  "",
  `> A quote with ${TOKEN} and ${URL}`,
  "",
  fence("text", `wide line: ${TOKEN}${TOKEN}`),
  "",
  `$$x = ${"a + b + c + d + e + f + g + h + ".repeat(8)}z$$`,
  "",
  "The end.",
].join("\n");

/// Waits for the diagram renderers (they load after the reply paints) so the shot shows drawn charts.
const drawn: Play = async (ctx) => {
  // A renderer that never draws still leaves a shot to look at.
  await ctx
    .waitFor(() => ctx.document.querySelectorAll(".cv-diagram__chart svg").length >= 3, { capMs: 15_000 })
    .catch(() => undefined);
  await ctx.waitFor(() => ctx.document.querySelector(".cv-thumb__img"), { capMs: 5_000 }).catch(() => undefined);
};

export default agentPaneEntry({
  id: "agent-pane.rich-blocks-audit",
  title: "Rich blocks: alignment audit",
  area: "Agent pane",
  height: 1800,
  covers: ["agent-session/acpmux/conversation/Markdown.tsx", "agent-session/acpmux/conversation/DiagramBlock.tsx"],
  variants: {
    mix: {
      note: "A table, mermaid diagram, vega-lite chart, pie chart, display math, a narrow image, a quote and code, each narrower than the column.",
      chipHost: HOST,
      height: 1800,
      snapshot: chat([user("Show every block", 3), assistant(MIX, 2.9), summary(2.9)]),
      play: drawn,
    },
    "long-strings": {
      note: "Long unbroken tokens and URLs in a heading, prose, inline code, a list, a quote, a code block and display math.",
      height: 1100,
      snapshot: chat([user("Paste the long things", 3), assistant(LONG, 2.9), summary(2.9)]),
    },
  },
});
