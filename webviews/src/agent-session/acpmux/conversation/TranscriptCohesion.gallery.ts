// l10n-allow-file: synthetic transcript fixtures, not shipped UI.
// One rhythm across harnesses, without giving Claude a whole-turn fold. References:
// chatgpt/live/transcript-thinking-and-tool-calls-consolidation and
// claude/live/transcript-agent-text-and-collapsed-tool-row.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../model";

function transcript(family: "codex" | "claude"): AcpmuxSnapshot {
  const snapshot = chat([
    user("Check the retry helper and report what you found.", 4),
    activity([
      tool("Read retry helper", "read", "completed", { output: "The helper retries server errors." }),
      tool("Check retry tests", "execute", "completed", { command: "bun test retry", output: "3 pass", exitCode: 0 }),
    ], 3),
    assistant("The helper already retries server errors and stops on client errors. All three focused tests pass.", 2),
    summary(1, { status: "completed", durationMs: 17_000, toolCount: 2 }),
  ], { harness: family, model: family === "codex" ? "gpt-6.1-sol" : "claude-opus-5-5" });
  return { ...snapshot, summary: { ...snapshot.summary!, family } };
}

export default agentPaneEntry({
  id: "agent-pane.transcript-cohesion",
  title: "Transcript rhythm across harnesses",
  area: "Agent pane",
  height: 460,
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor", "agent-session/acpmux/model.ts"],
  variants: {
    "codex-closed": {
      note: "Default Codex: Worked for is one 22px activity line, 16px from the reply.",
      snapshot: transcript("codex"),
    },
    "codex-open": {
      note: "Opened Codex: the work header and revealed run join the same 22px rhythm.",
      snapshot: transcript("codex"),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-worked.is-toggle"), { capMs: 10_000 });
        await ctx.click({ selector: ".cv-worked.is-toggle" });
      },
    },
    claude: {
      note: "Claude: each tool run has its own summary; the reply remains visible with no whole-turn Worked for.",
      snapshot: transcript("claude"),
    },
  },
});
