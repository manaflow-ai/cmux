// l10n-allow-file: gallery fixtures (sample prompts, versions, models and paths), not shipped UI.
// Where a Claude Code chat's session started: the transcript draws no line for it (Lucas,
// 2026-11-06, Codex parity: it landed inside the first turn's work and read as noise;
// rows/SessionStartRow.tsx). The row stays in the store for HarnessStatusCard. SessionStartNote.tsx
// keeps its own unit test.
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

const managed = () =>
  chat([
    user("Fix the flaky sidebar test", 4),
    row("sessionStart", 4, start("claude-sr2")),
    assistant("Looking at the sidebar test first.", 3),
    summary(3, { status: "completed", durationMs: 9_000, toolCount: 1 }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.session-start-note",
  title: "Session start note",
  area: "Agent pane",
  height: 320,
  covers: ["agent-session/acpmux/conversation/SessionStartNote.tsx"],
  variants: {
    managed: {
      note: "Play: a chat on sr2 with a session start row draws no line for it; the prompt and the reply alone.",
      snapshot: managed(),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.body.textContent?.includes("Looking at the sidebar test first."));
        if (ctx.document.querySelector(".cv-session-start")) throw new Error("a session start draws a line");
      },
    },
    stock: {
      note: "A chat on the person's own Claude Code setup: no session start line either.",
      snapshot: chat([
        user("Summarize the open PRs", 4),
        row("sessionStart", 4, start("claude")),
        assistant("Here are the open PRs.", 3),
        summary(3, { status: "completed", durationMs: 6_000, toolCount: 1 }),
      ]),
    },
  },
});
