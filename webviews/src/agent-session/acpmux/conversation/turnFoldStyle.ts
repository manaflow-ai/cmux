// How a finished turn folds, per harness family: one table, read once per turn by turns.ts.
//
// Leo, 2026-11-04: "doesn't make sense to fold claude's transcripts like that. do it for chatgpt,
// do the proper folds for however the other harnessses/model families fold (muse, gemini) but
// chatgpt-style minimalism conclusion folding can only necessarily make sense for them". Spec:
// leo-workspace design/chat-transcript.md "Turn fold per harness family".
import { agentKey } from "../../shared/agentKey";

export type TurnFoldStyle = {
  /// A finished turn's work, and the interim notes between it, goes under one closed "Worked for"
  /// line with only its conclusion in sight. False: no turn-level line; the work stays where it ran.
  conclusion: boolean;
  /// Each run of calls, the short notes inside it with it, folds into its own summary line ("Ran 3
  /// commands"): inside an open "Worked for", or in place where the turn has none. False: the calls
  /// draw one under another once the fold opens (a running turn's live runs aside).
  runs: boolean;
};

/// ChatGPT and Codex: the conclusion fold, the minimal end of turn only their apps draw.
const CODEX: TurnFoldStyle = { conclusion: true, runs: false };

/// Keyed by the harness family's agent (agentKey: "claude-sr2" is "claude"). A family missing here
/// folds as Codex does.
export const TURN_FOLD_STYLES: Readonly<Record<string, TurnFoldStyle>> = {
  codex: CODEX,
  // Claude: one "Worked for" at the top of the turn (Leo, 2026-11-04: "replacing the top level
  // thingy"); opened, its runs fold per run as Claude desktop draws them (cmux#30176).
  claude: { conclusion: true, runs: true },
  // Gemini CLI draws a turn as it ran: each run of calls in one tool box, no turn-level fold.
  gemini: { conclusion: false, runs: true },
  // Muse Code draws its turn as it ran too, with no conclusion fold: per-run lines in place.
  muse: { conclusion: false, runs: true },
};

/// The fold style of a harness family (acpmux's summary `family`).
export function turnFoldStyle(family: string | undefined): TurnFoldStyle {
  const key = agentKey(family);
  return (key !== undefined && Object.hasOwn(TURN_FOLD_STYLES, key) ? TURN_FOLD_STYLES[key] : undefined) ?? CODEX;
}
