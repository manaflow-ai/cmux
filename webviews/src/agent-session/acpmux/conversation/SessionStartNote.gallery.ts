// l10n-allow-file: gallery fixtures (sample prompts, versions, models and paths), not shipped UI.
// Where a Claude Code chat's session started (SessionStartNote.tsx): what it runs on, then how it
// compacts. sr2's harness manages compaction; the person's own Claude Code setup compacts the way
// Claude Code does.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";

const start = (harness: string) => ({
  sessionStart: {
    agent: "claude" as const,
    version: "2.1.303",
    model: "claude-opus-5-5",
    harness,
    cwd: "/Users/lawrence/fun/cmux",
  },
});

export default agentPaneEntry({
  id: "agent-pane.session-start-note",
  title: "Session start note",
  area: "Agent pane",
  height: 320,
  covers: ["agent-session/acpmux/conversation/SessionStartNote.tsx"],
  variants: {
    managed: {
      note: "A chat on sr2: Claude Code's version, model, route and folder, and that cmux manages compaction.",
      snapshot: chat([
        user("Fix the flaky sidebar test", 4),
        row("sessionStart", 4, start("claude-sr2")),
        assistant("Looking at the sidebar test first.", 3),
        summary(3, { status: "completed", durationMs: 9_000, toolCount: 1 }),
      ]),
    },
    stock: {
      note: "A chat on the person's own Claude Code setup: managed compaction is off.",
      snapshot: chat([
        user("Summarize the open PRs", 4),
        row("sessionStart", 4, start("claude")),
        assistant("Here are the open PRs.", 3),
        summary(3, { status: "completed", durationMs: 6_000, toolCount: 1 }),
      ]),
    },
  },
});
