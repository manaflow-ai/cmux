// l10n-allow-file: gallery fixtures (sample prompts, commands and reasons), not shipped UI.
// A background shell in the transcript. Its call's own "Ran" row says how it stands
// (BackgroundMark.tsx): running in the background, then finished, failed or stopped, wherever the
// call sits. A shell whose call is not in the transcript is noted where it ended
// (BackgroundTaskNote.tsx, cx-ncc.84), its command cut to the working step; opened, it shows the
// whole command and its output (BackgroundTaskNoteOpen.gallery.tsx).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { AcpmuxBackgroundState } from "../model";

/// A Bash call Claude ran in the background, and how its shell stands.
const shell = (command: string, background: AcpmuxBackgroundState, minutes: number) =>
  tool(command, "execute", "completed", {
    command,
    inputSummary: JSON.stringify({ command, run_in_background: true }),
    startedAt: minutesAgo(minutes),
    endedAt: minutesAgo(minutes) + 300,
    background,
  });

const LONG =
  'export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"; B=~/Projects/leo-workspace; cmux browser open https://example.com';

export default agentPaneEntry({
  id: "agent-pane.background-task-note",
  title: "Background task notes",
  area: "Agent pane",
  height: 360,
  covers: [
    "agent-session/acpmux/conversation/BackgroundTaskNote.tsx",
    "agent-session/acpmux/conversation/BackgroundMark.tsx",
  ],
  variants: {
    "on-call": {
      note: "Four background shells on their own Ran rows: still running (the running mark), finished (a check and the shell's whole time), failed, and stopped with the agent's reason on hover. No second row.",
      snapshot: chat([
        user("Start the dev server and the watchers", 9),
        activity(
          [
            shell("npm run dev", { state: "running" }, 8),
            shell("bun run build --watch", { state: "completed", endedAt: minutesAgo(5) }, 8),
            shell("cargo watch -x test", { state: "failed", endedAt: minutesAgo(4) }, 8),
            shell(
              "tail -f server.log",
              { state: "stopped", reason: "Stopped by the agent", endedAt: minutesAgo(3) },
              8,
            ),
          ],
          8,
        ),
        assistant("The dev server runs; the build finished, the test watcher failed on a compile error.", 2),
      ]),
    },
    lone: {
      note: "One background shell on its own row: running in the background, then the check and its time once it ends.",
      snapshot: chat([
        user("Run the suite in the background", 6),
        activity([shell("cargo test --workspace", { state: "running" }, 5)], 5),
        user("And the build?", 4),
        activity([shell("bun run build", { state: "completed", endedAt: minutesAgo(2) }, 3)], 3),
      ]),
    },
    ended: {
      note: "Shells whose calls are not in the transcript, each ending where it happened: the command cut to its working step, finished, failed, and stopped with the agent's reason. A click opens one in place (agent-pane.background-task-note-open).",
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
          backgroundTask: { toolCallId: "bg3", command: LONG, state: "completed" },
        }),
        assistant("The dev server is stopped; the test watcher failed on a compile error.", 2),
        summary(2, { status: "completed", durationMs: 9_000, toolCount: 1 }),
      ]),
    },
  },
});
