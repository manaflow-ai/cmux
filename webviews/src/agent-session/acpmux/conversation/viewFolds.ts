// The transcript's open folds under the chat's transcript view (transcriptView.ts; Leo,
// 2026-10-29: "i like these kinds of settings from claude code desktop..."). As in Claude Code
// desktop, Thinking and Verbose show a finished turn's work: its "Worked for" fold opens, so the
// thoughts and commands those views open are on screen. Normal is the reader's own folds, as before.
import { WORKED } from "./turns";
import type { TranscriptView } from "./transcriptView";

/// What the transcript asks of its open folds (turns.ts, subagentRows.ts, the fold animation).
export type Folds = Pick<ReadonlySet<string>, "has" | "size">;

export const NO_FOLD_TOGGLES: ReadonlySet<string> = new Set();

/// A turn's "Worked for" fold (turns.ts `${WORKED}-<row id>`).
export const isWorkedFold = (id: string): boolean => id.startsWith(`${WORKED}-`);

/// Normal: `expanded` itself, so its rows and their caching are today's. Thinking and Verbose:
/// every "Worked for" fold opens except one the reader toggled in that view (`toggled`); every
/// other fold stays the reader's. Build it once per view, set or toggle change (a memo), never per
/// event: turnViewFrom reuses its shaped turns while this object is the same.
export function viewFolds(view: TranscriptView, expanded: ReadonlySet<string>, toggled: ReadonlySet<string>): Folds {
  if (view === "normal") return expanded;
  return {
    has: (id) => (isWorkedFold(id) ? !toggled.has(id) : expanded.has(id)),
    // Never empty: each finished turn's fold is open (openFolds in turns.ts reads size first).
    size: expanded.size + 1,
  };
}
