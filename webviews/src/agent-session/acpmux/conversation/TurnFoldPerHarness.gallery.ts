// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// One finished turn per harness family, folded as its row of turnFoldStyle.ts says (Leo, 2026-11-04:
// "do it for chatgpt, do the proper folds for however the other harnessses/model families fold
// (muse, gemini)", then, on Claude: "you can't do it for Claude ... it's just too lossy if you do it
// for Claude"). For Codex parity (Lucas, 2026-11-06) every family now folds a finished turn under one
// "Worked for 12m 16s ›" over the reply: Codex's header counts the messages between the work, and
// Claude's, Gemini's and Muse's folds keep each run's own line inside. Claude's older in-place look
// (no turn fold) is the `runs` arm: compare both (claudeTurnFold.experiment.ts) in this entry's
// compare view. The after-gap-* variants compare the room after the line's rule (Leo, 2026-11-09).
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { claudeTurnFold } from "./claudeTurnFold.experiment";

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
    // Longer than a short note (SHORT_NOTE_CHARS), so it stays between the runs instead of joining one.
    assistant(
      "The loop retries any response that isn't ok, so a 404 waits through three backoffs before it fails. " +
        "I'm adding a status check there that fails a client error at once and keeps retrying 408 and 429.",
      15,
    ),
    activity(
      [run("Ran the retry tests", "bun test src/net"), run("Checked the branch is clean", "git status --short")],
      10,
    ),
    assistant(
      "Done. The helper now fails a 4xx at once, except 408 and 429, which still retry; a new test covers a 404.",
      8,
    ),
    summary(7.8, { status: "completed", durationMs: 736_000, toolCount: 5 }),
  ];
}

const snapshot = (family: string, harness: string, rows: AcpmuxRow[] = turn()) => {
  const base = chat(rows, { title: "Stop retrying client errors", harness });
  return { ...base, summary: { ...base.summary!, family } };
};

/// Leo's screenshot (2026-11-09: "ours looks like it still has a bit too much of a gap after the line
/// tho lucas fixed the before but we need to reduce the after"): a scheduled check's turn, its notice,
/// then "Worked for 44s · 3 tool calls" over the reply. Its rows carry the turn's `inBackground`; the
/// line does not.
function scheduledTurn(): AcpmuxRow[] {
  const id = "gallery-gap-check";
  return [
    ...turn(),
    row(BACKGROUND_TURN, 7, {
      id: backgroundTurnRowId(id),
      background: {
        id,
        trigger: "scheduled_wakeup",
        running: false,
        quiet: false,
        reason: "result",
        hasRows: true,
        ownTurn: true,
      },
    }),
    user("Start the re-review at the new head", 6.9, {
      incoming: { kind: "notice", text: "Start the re-review at the new head" },
      untyped: true,
    }),
    activity(
      [
        run("Read the branch head", "git rev-parse HEAD"),
        run("Started the review", "bun run review --head HEAD"),
        run("Checked the checks", "git log -1 --format=%H"),
      ],
      6.5,
      { inBackground: id },
    ),
    assistant(
      "The re-review is running at the new head. It waits up to 30 minutes for the rerun to finish, then tries the merge again, pinned to the reviewed commit.",
      6,
      { inBackground: id },
    ),
    summary(5.9, { status: "completed", durationMs: 44_000, toolCount: 3, inBackground: id }),
  ];
}

/// The room after the rule, other than the shipped 16 (the run gap): the stack measures the row, so
/// the rows under it follow.
const afterGap =
  (px: number): Play =>
  async (ctx) => {
    const style = ctx.document.createElement("style");
    style.textContent = `.cv-worked.has-divider.is-toggle { margin-bottom: ${px}px; }`;
    ctx.document.head.append(style);
    await ctx.waitFor(() => {
      const line = [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-1);
      return line !== undefined && getComputedStyle(line).marginBottom === `${px}px`;
    });
  };

/// The references, measured on Leo's screenshots (device px at 2x, label ink to the rule, then the
/// rule to the reply's ink).
const REFERENCES = "References: 10 then 59, and 18 then 44 (after 2.4 to 5.9 times before).";

/// Opens the turn's "Worked for" line where the arm draws one (Claude's opt-in); else nothing to do.
const openWorked: Play = async (ctx) => {
  const worked = () => ctx.document.querySelector<HTMLElement>(".cv-worked");
  if (worked()?.getAttribute("aria-expanded") === "false") {
    await ctx.click({ selector: ".cv-worked" });
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

const variant = (family: string, harness: string, note: string, play?: Play, rows?: AcpmuxRow[]): AgentPaneVariant => ({
  note,
  snapshot: snapshot(family, harness, rows),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.turn-fold-per-harness",
  title: "Turn fold per harness family",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 520, normal: 760, wide: 900 },
  // The fold each family's row of turnFoldStyle.ts picks (turns.ts) draws as these rows.
  covers: [
    "agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor",
    "agent-session/acpmux/conversation/TurnRows.tsx#ToolRows",
  ],
  // Claude's finished turn, under one Worked for (shipped) or runs in place (the older arm), opened.
  experiment: {
    definition: claudeTurnFold,
    script: [{ name: "Open the turn's Worked for, where it has one", run: openWorked }],
  },
  variants: {
    claude: variant(
      "claude",
      "claude",
      "Claude, by default: one closed Worked for over the reply (Codex parity); opened, each run of calls folds into its own line. The older in-place look, with no turn fold, is the runs arm (compare view).",
    ),
    codex: variant(
      "codex",
      "codex",
      "Codex and ChatGPT: the same closed fold; the reply between the runs stays in sight, never counted as a folded message.",
    ),
    gemini: variant(
      "gemini",
      "gemini",
      "Gemini CLI: one closed Worked for over the reply (Codex parity); opened, each run of calls folds into its own line.",
    ),
    muse: variant(
      "muse",
      "muse",
      "Muse Code: one closed Worked for over the reply (Codex parity), per-run lines inside.",
    ),
    // The room after the Worked for rule, on Leo's scheduled-check turn (worked-for-gap-after-browser.test.ts).
    // Each note gives label ink to rule, then rule to the reply's ink, in device px at 2x.
    "after-gap-12": variant(
      "codex",
      "codex",
      `12 under the rule (Lucas's room, #37727): 19 then 32, after 1.7 times before; tighter than the references. Before this change the scheduled turn stood the turn gap more: 19 then 96 (Leo's screenshot: 18 then 100). ${REFERENCES}`,
      afterGap(12),
      scheduledTurn(),
    ),
    "after-gap-16": variant(
      "codex",
      "codex",
      `Shipped: the run gap, 16, under the rule and no turn gap after it: 19 then 40, after 2.1 times before, nearest the reference whose before matches ours. ${REFERENCES}`,
      undefined,
      scheduledTurn(),
    ),
    "after-gap-20": variant(
      "codex",
      "codex",
      `20 under the rule: 19 then 48, after 2.5 times before; past the nearer reference, and off the grid's tokens. ${REFERENCES}`,
      afterGap(20),
      scheduledTurn(),
    ),
    "after-gap-8": variant(
      "codex",
      "codex",
      `8 under the rule (the grid gap): 19 then 24, after 1.3 times before; the reply crowds the line. ${REFERENCES}`,
      afterGap(8),
      scheduledTurn(),
    ),
  },
});
