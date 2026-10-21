// l10n-allow-file: gallery fixtures (sample prompts and commands), not shipped UI.
// A Claude Code chat's running command (BackgroundHint.tsx): its row ends with "⌃B to run in
// background", and Ctrl-B moves the command to the background (runInBackground.ts). A Codex chat's
// running command has no hint.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";

const suite = tool("cargo test --workspace", "execute", "in_progress", {
  command: "cargo test --workspace",
  inputSummary: JSON.stringify({ command: "cargo test --workspace" }),
  startedAt: minutesAgo(1),
});

const running = (harness: string) =>
  chat([user("Run the full test suite", 2), assistant("Running the suite.", 1.5), activity([suite], 1)], {
    harness,
    isWorking: true,
  });

export default agentPaneEntry({
  id: "agent-pane.background-hint",
  title: "Ctrl-B background hint",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/BackgroundHint.tsx"],
  variants: {
    claude: {
      note: "A Claude Code chat's running command: the row ends with the Ctrl-B hint.",
      snapshot: running("claude"),
    },
    codex: {
      note: "A Codex chat's running command: no hint, Ctrl-B stays the composer's.",
      snapshot: running("codex"),
    },
  },
});
