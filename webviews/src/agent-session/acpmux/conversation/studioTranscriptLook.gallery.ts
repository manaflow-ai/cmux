// l10n-allow-file: gallery fixtures (sample prompts, replies and code), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { studioTranscriptLook } from "./studioTranscriptLook.experiment";

const MID_TURN = chat([
  user("Add retries to the fetch helper and keep POSTs opt-in", 6),
  activity(
    [
      tool("Read src/net/client.ts", "read", "completed"),
      tool("Search for parseError", "search", "completed"),
      tool("Edit src/net/retry.ts", "edit", "completed"),
      tool("bun test src/net", "execute", "running", { command: "bun test src/net" }),
    ],
    5,
  ),
  assistant(
    "The retry policy is in place and the remaining checks are running.\n\n```ts\nexport async function withRetry<T>(run: () => Promise<T>) {\n  return run();\n}\n```",
    4,
  ),
]);

const CHAT_END = chat([...MID_TURN.rows, summary(3, { status: "completed", durationMs: 48_000, toolCount: 4 })]);

const arm = { "studio-transcript-look": "studio" };

const renderTranscript: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-row") !== null);
};

export default agentPaneEntry({
  id: "agent-pane.studio-transcript-look",
  title: "Studio transcript corners",
  area: "Agent pane",
  experimental: true,
  height: 820,
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  experiment: { definition: studioTranscriptLook, script: [{ name: "Render the transcript", run: renderTranscript }] },
  variants: {
    "mid-turn": {
      snapshot: MID_TURN,
      experiments: arm,
      note: "Prompt, tool rows and a reply with a code block while the turn is running.",
    },
    "chat-end": { snapshot: CHAT_END, experiments: arm, note: "The same chat after the turn ends." },
    "light-theme": {
      snapshot: CHAT_END,
      experiments: arm,
      theme: { appearance: "light" },
      note: "The Studio corners remain readable over a light theme's own ink and surfaces.",
    },
  },
});
