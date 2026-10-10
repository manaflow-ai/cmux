// Actions a turn's footer and edited-files card offer that reach past the transcript (to the
// client). A context, so a change in what acpmux serves, or in what the reader decided about a
// turn's hunks, reaches memoized rows without changing their versions.
import { createContext } from "react";
import type { HunkReview } from "../changes/hunkReview";

export type TurnActions = {
  /// Fork the session through the turn whose summary event is `throughSeq`; absent when
  /// acpmux does not serve forks.
  fork?: (throughSeq: number) => void;
  /// The only turn `fork` goes through (`latestForkSeq`): the latest completed turn.
  forkSeq?: number;
  /// Send a turn's prompt again (the last turn's Retry).
  retry?: (prompt: string) => void;
  /// Re-run the current harness's declared login command after an authentication failure.
  reauthenticate?: () => void;
  /// Who serves this chat's turns, for failure copy (cx-w10a): the harness profile's display name and id.
  route?: { name?: string; harness?: string };
  /// Opens the model and harness picker (a failure's "Switch model" action).
  switchModel?: () => void;
  /// The changes view's hunk decisions; a card's Undo asks for its turn's hunks through it, so
  /// the view shows them as requested too.
  review?: HunkReview;
};

export const TurnActionsContext = createContext<TurnActions>({});
