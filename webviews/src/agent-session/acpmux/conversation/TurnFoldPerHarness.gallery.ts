// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// One finished turn per harness family, folded as its row of turnFoldStyle.ts says (Leo, 2026-11-04:
// "do it for chatgpt, do the proper folds for however the other harnessses/model families fold
// (muse, gemini)", then, on Claude: "i think it should be the top level collapsible thing IF
// POSSIBLE... SOMETIMES there's just claude chatter that we could prob group up"). The same turn
// (two runs of calls, the chatter between them, then the conclusion) draws as ChatGPT's "Worked for
// 12m 16s ›" over the reply for Codex and Claude, opened as Claude desktop's per-run lines for
// Claude, and in place with no turn fold for Gemini and Muse.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity } from "../model";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });

function turn() {
  return [
    user("Make the fetch helper stop retrying client errors", 20),
    activity(
      [
        run("Found the retry loop", "rg -n 'retry' src/net/fetchWithRetry.ts"),
        run("Listed every caller", "rg -l fetchWithRetry src"),
        run("Read the retry tests", "sed -n '1,60p' src/net/fetchWithRetry.test.ts"),
      ],
      19,
    ),
    assistant("The loop retries any response that isn't ok, so I'm adding a status check there.", 15),
    activity(
      [
        run("Ran the retry tests", "bun test src/net"),
        run("Checked the branch is clean", "git status --short"),
      ],
      10,
    ),
    assistant(
      "Done. The helper now fails a 4xx at once, except 408 and 429, which still retry; a new test covers a 404.",
      8,
    ),
    summary(7.8, { status: "completed", durationMs: 736_000, toolCount: 5 }),
  ];
}

const snapshot = (family: string, harness: string) => {
  const base = chat(turn(), { title: "Stop retrying client errors", harness });
  return { ...base, summary: { ...base.summary!, family } };
};

/// Opens the turn's "Worked for" line.
const openWorked: Play = async (ctx) => {
  const worked = () => ctx.document.querySelector<HTMLElement>(".cv-worked");
  await ctx.waitFor(worked, { capMs: 10_000 });
  if (worked()?.getAttribute("aria-expanded") === "false") {
    await ctx.click({ selector: ".cv-worked" });
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

const variant = (family: string, harness: string, note: string, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: snapshot(family, harness),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.turn-fold-per-harness",
  title: "Turn fold per harness family",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/turnFoldStyle.ts", "agent-session/acpmux/conversation/turns.ts"],
  variants: {
    claude: variant(
      "claude",
      "claude",
      "Claude, chosen: ChatGPT's closed “Worked for 12m 16s” over the conclusion; the runs and the chatter between them fold under it.",
    ),
    "claude-open": variant(
      "claude",
      "claude",
      "Claude, opened: each run folds into its own line with the chatter between them, as Claude desktop draws a turn.",
      openWorked,
    ),
    codex: variant(
      "codex",
      "codex",
      "Codex and ChatGPT: the same closed fold; with messages between the work, Codex's header counts them.",
    ),
    gemini: variant(
      "gemini",
      "gemini",
      "Gemini CLI: no turn fold; each run of calls folds into its own line in place, as its tool boxes group them.",
    ),
    muse: variant(
      "muse",
      "muse",
      "Muse Code: no reference of how its app ends a turn, so no turn fold; per-run lines in place.",
    ),
  },
});
