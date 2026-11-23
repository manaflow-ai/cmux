// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import type { GoldenLook } from "../../../gallery/golden/look";
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { codexUserBubbleLook } from "./codexUserBubble.experiment";

// The draft Codex look's public tokens, delivered through the same stylesheet fixture as a setup.
const look: GoldenLook = {
  id: "example/codex-bubble",
  title: "Codex prompt paint",
  note: "The Codex look supplies an 8% white tint and 14px radius.",
  source: "docs/rfd/0008-customization-sdk-parity/looks/codex-look/agent-pane/theme.css",
  settings: {},
  schemes: { light: {}, dark: {} },
  themeCSS: ":root { --cv-user-bubble-tint: rgb(255 255 255 / 0.08); --cv-user-bubble-radius: 14px; }",
};

const snapshot = (prompt: string) =>
  chat([
    user(prompt, 9, { seq: 1 }),
    assistant("The prompt bubble keeps its message readable while the agent works.", 8.5),
    summary(8.5, { seq: 3, status: "completed" }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.codex-user-bubble-look",
  title: "Codex user bubble look",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/conversation/UserBubble.tsx", "agent-session/acpmux/conversation/conversation.css"],
  keywords: ["codex", "prompt", "bubble", "tint", "radius"],
  variants: {
    short: {
      note: "A short prompt, showing the bubble's fill and corner treatment without wrapping.",
      look,
      snapshot: snapshot("Use the Codex bubble treatment for this prompt."),
    },
    wrapped: {
      note: "A wrapped prompt, showing the same treatment over two lines of text.",
      look,
      snapshot: snapshot(
        "Use the Codex bubble treatment for this prompt, while keeping the message readable at the narrow chat width.",
      ),
    },
    long: {
      note: "A longer prompt, showing the treatment around a multi-line message.",
      look,
      snapshot: snapshot(
        "Use the Codex bubble treatment for this prompt. Keep the text in one readable block and preserve the existing prompt actions below it.",
      ),
    },
  },
  experiment: {
    definition: codexUserBubbleLook,
    script: [
      {
        name: "Select prompt text",
        run: async (ctx) => {
          await ctx.waitFor(() => document.querySelector(".cv-user__bubble"));
          await ctx.selectText({ selector: ".cv-user__bubble" });
        },
      },
    ],
  },
});
