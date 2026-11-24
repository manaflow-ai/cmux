// l10n-allow-file: gallery fixtures and experiment controls, not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../gallery/fixtures/acpmux";
import { highContrastLook } from "./highContrastLook.experiment";

const snapshot = chat([
  user("Review the fetch helper and explain how to handle failures.", 4),
  activity(
    [
      tool("Read src/fetch.ts", "read", "completed", {
        output: "export const fetchText = async (url) => (await fetch(url)).text();",
      }),
    ],
    3.9,
  ),
  assistant(
    "The helper returns response text.\n\n```ts\nconst text = await fetchText(url);\n```\n\nSee the [Fetch documentation](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API) for error handling.",
    3.8,
  ),
  summary(3.8, { status: "completed", toolCount: 1 }),
]);

export default agentPaneEntry({
  id: "agent-pane.high-contrast-look",
  title: "High contrast chat",
  area: "Agent pane",
  experimental: true,
  height: 700,
  covers: ["agent-session/acpmux/chatDisplay.ts", "agent-session/acpmux/highContrastLook.experiment.ts"],
  variants: {
    standard: {
      snapshot,
      display: {},
      note: "Current theme and saved type; compare the default-off arm.",
    },
    custom: {
      snapshot,
      display: {
        "agentPane.display.width": 640,
        "agentPane.display.font.size": 12,
      },
      note: "Small saved type and narrow column; High contrast changes only the disposable experiment view.",
    },
  },
  experiment: {
    definition: highContrastLook,
    script: [
      {
        name: "Open the tool output",
        run: async (ctx) => {
          const folded = ".cv-worked.is-toggle[aria-expanded=false]";
          if (ctx.document.querySelector(folded)) await ctx.click({ selector: folded });
          const output = ".cv-tool.is-toggle[aria-expanded=false]";
          await ctx.waitFor(() => ctx.document.querySelector(output), {
            capMs: 10_000,
          });
          await ctx.click({ selector: output });
        },
      },
    ],
  },
});
