// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { chatMinimapPlaceholder } from "./placeholder.experiment";

// The VS Code Minimap (ChatMinimap.tsx) with the setting on, at the right edge of a 60-prompt chat.
// While the last reply streams, the minimap is frozen and that reply's place is a placeholder; the
// compare view shows each look (placeholder.experiment.ts) side by side. Synthetic prompts only.
const turns = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    user(`Prompt ${index + 1}: check the next part of the plan`, 400 - index * 3),
    assistant(
      `Part ${index + 1} checked.\n\n${index % 3 ? "A second paragraph so the turn has some height." : "A longer reply this time, with a list:\n\n- one\n- two\n- three\n\nand a closing line."}`,
      399.8 - index * 3,
    ),
    summary(399.6 - index * 3, { status: "completed" }),
  ]).flat();
const done = turns(30);
const streaming = [
  ...done,
  user("Prompt 61: write the release notes", 2),
  assistant(
    `Drafting the release notes now.\n\n${Array.from({ length: 14 }, (_, index) => `${index + 1}. A note about change ${index + 1}, with a sentence that wraps onto a second line of the reply.`).join("\n\n")}`,
    1,
    { streaming: true },
  ),
];
const display = { "agentPane.display.vscodeMinimap": true };

export default agentPaneEntry({
  id: "agent-pane.chat-minimap",
  title: "VS Code Minimap",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 1040, normal: 1240, wide: 1440 },
  anchors: [{ selector: ".acpmux-chat-minimap" }],
  covers: ["agent-session/acpmux/chatMinimap/ChatMinimap.tsx#ChatMinimap"],
  experiment: {
    definition: chatMinimapPlaceholder,
    script: [
      {
        // Both variants: the picture drawn (the streaming one draws the rows above its reply, and its
        // placeholder comes in the same pass; the at-rest one has none).
        name: "drawn",
        run: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-minimap canvas[data-draws]")),
      },
    ],
  },
  variants: {
    streaming: {
      note: "The last reply streams: everything above it is drawn, and its place is the placeholder (this arm's look) until it ends.",
      snapshot: chat(streaming, { title: "VS Code Minimap, streaming" }),
      display,
      play: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-minimap__placeholder")),
    },
    "at-rest": {
      note: "No reply streaming: the whole chat drawn, prompts as accent bars at the right, replies as text lines, the view box at the reader's place.",
      snapshot: chat(done, { title: "VS Code Minimap, at rest" }),
      display,
      play: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-minimap canvas[data-draws]")),
    },
  },
});
