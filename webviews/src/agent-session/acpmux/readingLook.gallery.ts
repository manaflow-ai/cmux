// l10n-allow-file: gallery fixtures and experiment controls, not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../gallery/fixtures/acpmux";
import { readingLook } from "./readingLook.experiment";

const snapshot = chat([
  user("Review the small fetch helper and explain how to use it.", 4),
  activity(
    [
      tool("Read src/fetch.ts", "read", "completed", {
        output: "export const fetchText = async (url) => (await fetch(url)).text();",
      }),
    ],
    3.9,
  ),
  assistant(
    "The helper returns the response as text.\n\n```ts\nconst text = await fetchText(url);\n```\n\nCheck the [Fetch documentation](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API) for error handling.",
    3.8,
  ),
  summary(3.8, { status: "completed", toolCount: 1 }),
]);

export default agentPaneEntry({
  id: "agent-pane.claude-reading-layout",
  title: "Claude reading layout",
  area: "Agent pane",
  experimental: true,
  height: 700,
  covers: ["agent-session/acpmux/chatDisplay.ts", "agent-session/acpmux/readingLook.experiment.ts"],
  variants: {
    standard: { snapshot, display: {}, note: "Default settings: compare 800/14 with the design's 720/15." },
    custom: {
      snapshot,
      display: { "agentPane.display.width": 960, "agentPane.display.font.size": 18 },
      note: "A saved 960-point column and 18-point text; Off preserves both.",
    },
    "full-width": {
      snapshot,
      display: { "agentPane.display.fullWidth": true },
      note: "Reading uses its capped column; Type only and Off preserve Full Width.",
    },
  },
  experiment: {
    definition: readingLook,
    script: [
      {
        name: "Open the tool output",
        run: async (ctx) => {
          const folded = ".cv-worked.is-toggle[aria-expanded=false]";
          if (ctx.document.querySelector(folded)) await ctx.click({ selector: folded });
          const output = ".cv-tool.is-toggle[aria-expanded=false]";
          await ctx.waitFor(() => ctx.document.querySelector(output), { capMs: 10_000 });
          await ctx.click({ selector: output });
        },
      },
    ],
  },
});
