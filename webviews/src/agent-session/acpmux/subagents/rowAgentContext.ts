import { createContext } from "react";

/** A transcript row retains this snapshot while hidden. It uses a distinct context so React's
 * lazy propagation of the pane's agent contexts cannot wake consumers inside a retained body. */
export const RowAgentContext = createContext<
  | {
      names: ReadonlyMap<string, string>;
      open: { views: ReadonlyMap<string, string>; open(viewId: string): void } | undefined;
      tones: ReadonlyMap<string, number> | undefined;
    }
  | undefined
>(undefined);
