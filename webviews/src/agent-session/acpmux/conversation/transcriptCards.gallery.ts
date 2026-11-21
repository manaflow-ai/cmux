// l10n-allow-file: public-safe demo workspace, never a real conversation.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { transcriptCards } from "./transcriptCards.experiment";

const rows = (working = false) => [
  user("Add a retry limit to the demo fetch helper", 4),
  activity(
    [
      tool("Inspect src/fetch.ts", "other", "completed", {
        output: "export const retryLimit = 2;\nexport const timeout = 1000;",
      }),
    ],
    3,
  ),
  activity(
    [
      tool("Edit src/fetch.ts", "edit", "completed", {
        diffs: [
          {
            path: "src/fetch.ts",
            oldText: "export const retryLimit = 2;\n",
            newText: "export const retryLimit = 3;\n",
          },
        ],
      }),
    ],
    2,
  ),
  assistant(
    "The helper now stops after three retries.\n\n```ts\nexport const retryLimit = 3;\n```\n\nSee the [demo documentation](https://example.com).",
    1,
    { streaming: working },
  ),
];

const openOutput: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("button.cv-tool"));
  if (ctx.find({ selector: "button.cv-tool" }).getAttribute("aria-expanded") !== "true")
    await ctx.click({ selector: "button.cv-tool" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-tool-output-card"));
};

export default agentPaneEntry({
  id: "agent-pane.transcript-cards",
  title: "Borderless transcript cards",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 390, normal: 640, wide: 960 },
  covers: ["agent-session/acpmux/VirtualTranscript.tsx", "agent-session/acpmux/conversation/conversation.css"],
  experiment: {
    definition: transcriptCards,
    script: [{ name: "Open tool output", run: openOutput }],
  },
  variants: {
    chat: {
      note: "SHOTS chat: a prompt, tool rows, reply with code and link. Compare both experiment arms.",
      snapshot: chat(rows(true), { harness: "codex", model: "gpt-6-astra", isWorking: true }),
    },
    cards: {
      note: "SHOTS cards: opened output beside the turn's edited-file card. The current arm remains the default.",
      snapshot: chat(rows(), { harness: "codex", model: "gpt-6-astra" }),
      play: openOutput,
    },
    "chat-end": {
      note: "SHOTS chat-end: completed turn with the unchanged default composer. Compare light and dark environments to see the dark-only paint limitation.",
      snapshot: chat([...rows(), summary(0.5, { status: "completed" })], { harness: "codex", model: "gpt-6-astra" }),
    },
  },
});
