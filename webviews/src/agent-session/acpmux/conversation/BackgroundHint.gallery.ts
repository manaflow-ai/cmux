// l10n-allow-file: gallery fixtures (sample prompts and commands), not shipped UI.
// A Claude Code chat's running command (BackgroundHint.tsx): its row ends with "⌃B to run in
// background", and Ctrl-B moves the command to the background (runInBackground.ts). The model
// router's `cmux` chat is Claude Code too. A Codex chat's running command, or an ACP agent's that a
// user named `claude-acp`, has no hint: acpmux's summary says which (`backgroundsWork`).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";

const suite = tool("cargo test --workspace", "execute", "in_progress", {
  command: "cargo test --workspace",
  inputSummary: JSON.stringify({ command: "cargo test --workspace" }),
  startedAt: minutesAgo(1),
});

const running = (harness: string, backgroundsWork = harness === "claude") =>
  chat([user("Run the full test suite", 2), assistant("Running the suite.", 1.5), activity([suite], 1)], {
    harness,
    backgroundsWork,
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
    router: {
      note: "The model router's chat (Claude Code named `cmux`): the row ends with the Ctrl-B hint.",
      snapshot: running("cmux", true),
    },
    codex: {
      note: "A Codex chat's running command: no hint, Ctrl-B stays the composer's.",
      snapshot: running("codex"),
    },
    "claude-acp": {
      note: "An ACP agent a user named `claude-acp`: acpmux refuses its Ctrl-B, so no hint.",
      snapshot: running("claude-acp", false),
    },
  },
});
