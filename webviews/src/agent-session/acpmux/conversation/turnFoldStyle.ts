// How a finished turn folds, per harness family: one table, read once per turn by turns.ts.
//
// Leo, 2026-11-04: "doesn't make sense to fold claude's transcripts like that. do it for chatgpt,
// do the proper folds for however the other harnessses/model families fold (muse, gemini)", then:
// "i think it should be the top level collapsible thing IF POSSIBLE... SOMETIMES there's just claude
// chatter that we could prob group up", and later, on Claude: "you can't do it for Claude ... it's
// just too lossy if you do it for Claude". Spec: leo-workspace design/chat-transcript.md "Turn fold
// per harness family". Lucas, 2026-11-06 (Codex parity for every model): every family
// folds a finished turn under one "Worked for"; Claude's in-place runs stay as the experiment's other arm.
import { experimentArm } from "../../../experiments/experiment";
import { agentKey } from "../../shared/agentKey";
import { claudeTurnFold } from "./claudeTurnFold.experiment";

export type TurnFoldStyle = {
  /// A finished turn's work, and the short notes between it, goes under one closed "Worked for" line,
  /// as ChatGPT and Codex end a turn. Its replies to the person stay in sight, the conclusion and
  /// every earlier one, with the work around each on its own closed line (turns.ts `aroundReplies`).
  /// False: no turn-level line; the work stays where it ran.
  conclusion: boolean;
  /// A run that edited takes the short notes around it too, as other runs do (turns.ts
  /// `mergeShortNotes` `edits`), as Claude desktop draws a turn: inside an open "Worked for", or in
  /// place where the turn has none. Every family's runs of calls fold into their summary lines
  /// ("Ran 3 commands"); false only keeps an edit's short notes beside it.
  runs: boolean;
  /// The closed line counts the fold's messages, "6 previous messages", when the agent's own short
  /// notes sit between its work, as Codex's header does; a reply in sight is never one of them. False: it always reads "Worked for Ns",
  /// as ChatGPT's.
  countsMessages: boolean;
  /// The closed line counts every call the turn made after its time, "Worked for 2m 17s · 14 tool
  /// calls": the turn's one outer level, over the runs between its asides, each of which counts only
  /// its own calls (toolGroups.ts `isAside`). False: the time alone, as Codex's header reads.
  countsCalls: boolean;
};

/// ChatGPT and Codex: the conclusion fold, under Codex's own header.
const CODEX: TurnFoldStyle = { conclusion: true, runs: false, countsMessages: true, countsCalls: false };

/// The fold every other family gets: one closed "Worked for 36s" over the
/// conclusion, never a message count; opened, its runs fold per run.
const WORKED_FOR: TurnFoldStyle = { conclusion: true, runs: true, countsMessages: false, countsCalls: true };

/// Keyed by the harness family's agent (agentKey: "claude-sr2" is "claude"). A family missing here
/// folds as Codex does, as every family but Claude did before this table.
export const TURN_FOLD_STYLES: Readonly<Record<string, TurnFoldStyle>> = {
  codex: CODEX,
  // Claude, Gemini and Muse: the whole-turn fold. Claude's in-place runs (Claude desktop's
  // look, cmux#30176) are the `runs` arm of claudeTurnFold.experiment.ts.
  claude: WORKED_FOR,
  gemini: WORKED_FOR,
  muse: WORKED_FOR,
};

/// Claude's other arm (`runs` in claudeTurnFold.experiment.ts): no turn fold, each run of calls on
/// its own line in place as Claude desktop draws it, the prose between runs in sight.
export const CLAUDE_IN_PLACE: TurnFoldStyle = {
  conclusion: false,
  runs: true,
  countsMessages: false,
  countsCalls: false,
};

/// The fold style of a harness family (acpmux's summary `family`); undefined folds as Codex does.
/// `claudeInPlace` defaults to the experiment's arm, so a Claude turn keeps its runs in place only there.
export function turnFoldStyle(
  family: string | undefined,
  claudeInPlace: () => boolean = () => experimentArm(claudeTurnFold) === "runs",
): TurnFoldStyle {
  const key = agentKey(family);
  if (key === "claude" && claudeInPlace()) return CLAUDE_IN_PLACE;
  return (key && Object.hasOwn(TURN_FOLD_STYLES, key) ? TURN_FOLD_STYLES[key] : undefined) ?? CODEX;
}
