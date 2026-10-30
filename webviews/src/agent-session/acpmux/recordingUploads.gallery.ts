// l10n-allow-file: synthetic recording and transcript for the attachment regression.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";

const snapshot = chat([
  user("Please use the recording with these notes.", 2),
  assistant("Attach the original recording, then send the notes when ready.", 1),
  summary(1, { status: "completed" }),
]);
snapshot.summary = { ...snapshot.summary!, promptCapabilities: { audio: true } };

export default agentPaneEntry({
  id: "agent-pane.recording-uploads",
  title: "Large voice recording as a file",
  area: "Agent pane",
  height: 560,
  variants: {
    "large-inline-recording": {
      note: "An older host's 5 MiB inline recording is uploaded in chunks and retained as a file chip.",
      ready: { cwd: "/Users/dev/src/atlas-web" },
      snapshot,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-md"));
        const bridge = ctx.document.defaultView!.cmuxAcpmuxBridge!;
        bridge.dictation!({ state: "listening", text: "Keep the original", level: 0.4, cancelled: false });
        // Zero-filled synthetic audio, never a private recording. The real host supplies base64.
        const bytes = 5 * 1024 * 1024;
        const data = "AAAA".repeat(Math.floor(bytes / 3)) + "AAA=";
        bridge.dictation!({
          state: "idle",
          text: "Keep the original recording with these notes.",
          level: 0,
          cancelled: false,
          audio: { mimeType: "audio/wav", data },
        });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-md")?.textContent?.includes("with these notes"));
      },
    },
  },
});
