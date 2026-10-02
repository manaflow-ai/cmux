// Actions a turn's footer offers that reach past the transcript (to the client). A context, so
// a change in what acpmux serves reaches memoized rows without changing their versions.
import { createContext } from "react";

export type TurnActions = {
  /// Fork the session through the turn whose summary event is `throughSeq`; absent when
  /// acpmux does not serve forks.
  fork?: (throughSeq: number) => void;
};

export const TurnActionsContext = createContext<TurnActions>({});
