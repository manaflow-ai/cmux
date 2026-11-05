// How a finished turn folds, per harness family: one table, read once per turn by turns.ts.
//
// Leo, 2026-11-04: "doesn't make sense to fold claude's transcripts like that. do it for chatgpt,
// do the proper folds for however the other harnessses/model families fold (muse, gemini)", then:
// "i think it should be the top level collapsible thing IF POSSIBLE... SOMETIMES there's just claude
// chatter that we could prob group up", and later, on Claude: "you can't do it for Claude ... it's
// just too lossy if you do it for Claude". Spec: leo-workspace design/chat-transcript.md "Turn fold
// per harness family".
import { experimentArm } from "../../../experiments/experiment";
import { agentKey } from "../../shared/agentKey";
import { usesT3Activity } from "./toolActivityPresentation.experiment";
import { claudeTurnFold } from "./claudeTurnFold.experiment";

export type TurnFoldStyle = {
  /// A finished turn's work, and the interim chatter between it, goes under one closed "Worked for"
  /// line with only the conclusion (its last reply after the last call) in sight, as ChatGPT and
  /// Codex end a turn. False: no turn-level line; the work stays where it ran.
  conclusion: boolean;
  /// Each run of calls, the short notes inside it with it, folds into its own summary line ("Ran 3
  /// commands"), as Claude desktop draws a turn: inside an open "Worked for", or in place where
  /// the turn has none. False: the calls draw one under another (a running turn's live runs aside).
  runs: boolean;
  /// The closed line counts the fold's messages, "6 previous messages", when the agent's own
  /// messages sit between its work, as Codex's header does. False: it always reads "Worked for Ns",
  /// as ChatGPT's.
  countsMessages: boolean;
};

/// ChatGPT and Codex: the conclusion fold, under Codex's own header.
const CODEX: TurnFoldStyle = { conclusion: true, runs: false, countsMessages: true };

/// Keyed by the harness family's agent (agentKey: "claude-sr2" is "claude"). A family missing here
/// folds as Codex does, as every family but Claude did before this table.
export const TURN_FOLD_STYLES: Readonly<Record<string, TurnFoldStyle>> = {
  codex: CODEX,
  // Claude: no turn fold by default, each run of calls on its own line in place as Claude desktop
  // draws it (cmux#30176), the prose between runs in sight. The whole-turn fold is an opt-in only
  // (CLAUDE_WORKED_FOR): "it's just too lossy if you do it for Claude".
  claude: { conclusion: false, runs: true, countsMessages: false },
  // Gemini CLI draws a turn as it ran, with each run of calls grouped in one tool box and no
  // turn-level fold: per-run lines, no "Worked for".
  gemini: { conclusion: false, runs: true, countsMessages: false },
  // Muse Code: no reference of how its app ends a turn, so no turn fold (the per-run lines Claude
  // turns had before), until one shows otherwise.
  muse: { conclusion: false, runs: true, countsMessages: false },
};

/// Claude's opt-in (the `worked-for` arm of claudeTurnFold.experiment.ts): ChatGPT's "Worked for
/// 12m 16s ›" over the conclusion, never a message count; opened, its runs fold per run.
export const CLAUDE_WORKED_FOR: TurnFoldStyle = { conclusion: true, runs: true, countsMessages: false };

const T3: TurnFoldStyle = { conclusion: true, runs: false, countsMessages: false };

/// The fold style of a harness family (acpmux's summary `family`); undefined folds as Codex does.
/// `claudeWorkedFor` defaults to the experiment's arm, so a Claude turn folds whole only when opted in.
export function turnFoldStyle(
  family: string | undefined,
  claudeWorkedFor: () => boolean = () => experimentArm(claudeTurnFold) === "worked-for",
): TurnFoldStyle {
  if (usesT3Activity()) return T3;
  const key = agentKey(family);
  if (key === "claude" && claudeWorkedFor()) return CLAUDE_WORKED_FOR;
  return (key && Object.hasOwn(TURN_FOLD_STYLES, key) ? TURN_FOLD_STYLES[key] : undefined) ?? CODEX;
}
