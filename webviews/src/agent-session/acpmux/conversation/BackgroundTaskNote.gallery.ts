// l10n-allow-file: gallery fixtures (sample prompts, commands and reasons), not shipped UI.
// A background shell's end in the transcript (BackgroundTaskNote.tsx, cx-ncc.84): finished,
// failed, and stopped with the agent's reason, each where it happened.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";

export default agentPaneEntry({
  id: "agent-pane.background-task-note",
  title: "Background task notes",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/BackgroundTaskNote.tsx"],
  variants: {
    ended: {
      note: "Three background shells ending: finished, failed, and stopped with the agent's reason.",
      snapshot: chat([
        user("Stop the dev server and check the watchers", 5),
        row("backgroundTask", 4, {
          backgroundTask: {
            toolCallId: "bg1",
            command: "npm run dev",
            state: "stopped",
            reason: "Stopped by the agent",
          },
        }),
        row("backgroundTask", 4, {
          backgroundTask: { toolCallId: "bg2", command: "cargo watch -x test", state: "failed" },
        }),
        row("backgroundTask", 3, {
          backgroundTask: { toolCallId: "bg3", command: "bun run build --watch", state: "completed" },
        }),
        assistant("The dev server is stopped; the test watcher failed on a compile error.", 2),
        summary(2, { status: "completed", durationMs: 9_000, toolCount: 1 }),
      ]),
    },
  },
});
