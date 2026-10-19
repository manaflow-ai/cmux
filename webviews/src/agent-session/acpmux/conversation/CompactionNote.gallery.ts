// l10n-allow-file: gallery fixtures (sample prompts and harness names), not shipped UI.
// Compaction and failover notes in the transcript (CompactionNote.tsx): a compaction running, one
// subrouter ran to move the chat to another account, and acpmux moving the chat to its fallback
// harness after a usage limit.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";

export default agentPaneEntry({
  id: "agent-pane.compaction-note",
  title: "Compaction and failover notes",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/CompactionNote.tsx"],
  variants: {
    accountSwitch: {
      note: "subrouter compacted the chat before moving it to another account, then the turn went on.",
      snapshot: chat([
        user("Finish the migration and run the tests", 6),
        row("compaction", 5, {
          compaction: { state: "completed", reason: "account_switch", preTokens: 412_000, postTokens: 18_400 },
        }),
        assistant("Picking up where we left off: the migration is applied, running the tests now.", 4),
        summary(4, { status: "completed", durationMs: 41_000, toolCount: 2 }),
      ]),
    },
    running: {
      note: "A compaction while it runs, and one that failed.",
      snapshot: chat([
        user("/compact", 3),
        row("compaction", 3, { compaction: { state: "failed" } }),
        user("/compact", 2),
        row("compaction", 2, { compaction: { state: "running" } }),
      ]),
    },
    failover: {
      note: "The Claude pool hit its usage limit; acpmux moved the chat to its fallback harness.",
      snapshot: chat([
        user("Keep going on the refactor", 4),
        row("failover", 4, { failover: { from: "claude-sr2", to: "codex" } }),
        assistant("Continuing the refactor from the restored context.", 3),
        summary(3, { status: "completed", durationMs: 12_000, toolCount: 0 }),
      ]),
    },
  },
});
