// l10n-allow-file: gallery fixtures (sample prompts, versions, models and paths), not shipped UI.
// Where a Claude Code chat's session started (SessionStartNote.tsx): what it runs on in one short
// line, then how it compacts in one line; a click opens either. sr2's harness manages compaction;
// the person's own Claude Code setup compacts the way Claude Code does.
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
      note: 'A chat on sr2: "Claude Code · Opus 5.5 · sr2", then "cmux manages compaction · Learn more", each one quiet line.',
      snapshot: managed(),
    },
    details: {
      note: "A click on the facts line opens the whole of it: Claude Code's version, the model id, the route and the folder.",
      snapshot: managed(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-session-start" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-session-start__detail"));
      },
    },
    explained: {
      note: "Learn more opens how cmux manages the chat's compaction; the dismiss X stays on the line.",
      snapshot: managed(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-session-start__more" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-session-start__detail"));
      },
    },
    stock: {
      note: 'A chat on the person\'s own Claude Code setup: "Claude Code · Opus 5.5", then "Claude Code compacts on its own · Learn more".',
      snapshot: chat([
        user("Summarize the open PRs", 4),
        row("sessionStart", 4, start("claude")),
        assistant("Here are the open PRs.", 3),
        summary(3, { status: "completed", durationMs: 6_000, toolCount: 1 }),
      ]),
    },
  },
});
